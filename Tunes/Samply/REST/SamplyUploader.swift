import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class SamplyUploader: ProjectAssetUploading {
    enum Status: Equatable {
        case idle, preparing, uploading, completed, cancelled, uncertain(String), failed(String)
    }

    nonisolated static let ticketTimeout: TimeInterval = 30
    nonisolated static let filePutTimeout: TimeInterval = 120
    nonisolated static let artworkPutTimeout: TimeInterval = 60

    private(set) var status: Status = .idle
    private(set) var progress: Double = 0
    private(set) var fileName = ""
    private(set) var uploadedBoxID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private let api: SamplyAPI
    @ObservationIgnored private let storageConfiguration: URLSessionConfiguration?
    @ObservationIgnored private let ticketTimeout: TimeInterval
    @ObservationIgnored private let filePutTimeout: TimeInterval
    @ObservationIgnored private let artworkPutTimeout: TimeInterval

    var isRunning: Bool { status == .preparing || status == .uploading }

    init(api: SamplyAPI, storageConfiguration: URLSessionConfiguration? = nil,
         ticketTimeout: TimeInterval = SamplyUploader.ticketTimeout,
         filePutTimeout: TimeInterval = SamplyUploader.filePutTimeout,
         artworkPutTimeout: TimeInterval = SamplyUploader.artworkPutTimeout) {
        self.api = api
        self.storageConfiguration = storageConfiguration
        self.ticketTimeout = max(0.1, ticketTimeout)
        self.filePutTimeout = max(0.1, filePutTimeout)
        self.artworkPutTimeout = max(0.1, artworkPutTimeout)
    }

    /// The album uploader's visible single-file flow. The token is captured by
    /// the caller when the operation starts; a later replacement is not silently
    /// read halfway through.
    func upload(file: URL, projectID: String, parentID: String? = nil, token: String? = nil) {
        guard !isRunning else { return }
        let id = UUID()
        operationID = id
        status = .preparing
        progress = 0
        fileName = file.lastPathComponent
        uploadedBoxID = nil
        task = Task { [weak self] in
            guard let self else { return }
            self.status = .uploading
            let outcome = await self.transfer(
                kind: .originalFile, projectID: projectID, parentID: parentID,
                fileName: file.lastPathComponent, mimeType: nil, size: nil,
                fileURL: file, data: nil, token: token, authorization: nil
            ) { [weak self] value in
                guard let self, self.operationID == id, self.status == .uploading else { return }
                self.progress = max(self.progress, min(max(value, 0), 1))
            }
            guard self.operationID == id else { return }
            switch outcome.disposition {
            case .submitted:
                self.progress = 1
                self.uploadedBoxID = outcome.ticket?.boxID
                self.status = .completed
            case .cancelled:
                if outcome.isSafelyRetryable {
                    self.status = .cancelled
                } else {
                    self.status = .uncertain(Self.message(for: outcome))
                }
            case .failed(let message):
                self.status = .failed(message)
            case .uncertain(let message):
                self.status = .uncertain(message)
            }
        }
    }

    func performUpload(file: URL, projectID: String, parentID: String?,
                       authorization: UploadAuthorization,
                       progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UploadOutcome {
        await transfer(
            kind: .originalFile, projectID: projectID, parentID: parentID,
            fileName: file.lastPathComponent, mimeType: nil, size: nil,
            fileURL: file, data: nil, token: authorization.credential.token,
            authorization: authorization, progress: progress)
    }

    func performArtworkUpload(payload: ProjectArtworkPayload, projectID: String,
                              authorization: UploadAuthorization) async -> UploadOutcome {
        await transfer(
            kind: .artwork, projectID: projectID, parentID: nil,
            fileName: payload.fileName, mimeType: payload.mimeType,
            size: Int64(payload.data.count), fileURL: nil, data: payload.data,
            token: authorization.credential.token, authorization: authorization,
            progress: nil)
    }

    func cancel() {
        // Do not declare a cancellation until the transfer reports its phase. A
        // successful PUT response that races this request must remain a success.
        task?.cancel()
    }

    func reset() {
        task?.cancel()
        task = nil
        operationID = UUID()
        status = .idle
        progress = 0
        fileName = ""
        uploadedBoxID = nil
    }

    private func transfer(
        kind: UploadKind, projectID: String, parentID: String?,
        fileName: String, mimeType: String?, size: Int64?,
        fileURL: URL?, data: Data?, token: String?,
        authorization: UploadAuthorization?,
        progress: (@MainActor @Sendable (Double) -> Void)?
    ) async -> UploadOutcome {
        if let authorization, !authorization.isCurrent {
            return .cancelled(.waiting)
        }
        guard !Task.isCancelled else { return .cancelled(.waiting) }

        var scoped = false
        if let fileURL {
            scoped = fileURL.startAccessingSecurityScopedResource()
        }
        defer { if scoped { fileURL?.stopAccessingSecurityScopedResource() } }

        let prepared: PreparedUpload
        do {
            prepared = try prepare(kind: kind, fileURL: fileURL, data: data,
                                   mimeType: mimeType, size: size, fileName: fileName)
        } catch {
            return .failed(Self.localFailureMessage(error), phase: .waiting)
        }

        guard !Task.isCancelled else { return .cancelled(.waiting) }
        if let authorization, !authorization.isCurrent {
            return .cancelled(.waiting)
        }

        let ticket: UploadTicket
        do {
            switch kind {
            case .originalFile:
                ticket = try await api.uploadTicket(
                    projectID: projectID, name: fileName, mimeType: prepared.mimeType,
                    size: prepared.size, parentID: parentID, token: token,
                    timeout: ticketTimeout)
            case .artwork:
                ticket = try await api.artworkTicket(
                    projectID: projectID, name: fileName, mimeType: prepared.mimeType,
                    size: prepared.size, token: token, timeout: ticketTimeout)
            }
        } catch {
            return Self.ticketFailure(error)
        }

        guard !ticket.boxid.isEmpty else {
            return .failed("Samply returned an upload ticket without an asset identity.",
                           phase: .ticketRequested)
        }
        let identity = UploadTicketIdentity(
            boxID: ticket.boxid, projectID: projectID, fileName: fileName, kind: kind)

        if let authorization, !authorization.isCurrent {
            return .cancelled(.ticketReceived, ticket: identity)
        }
        guard !Task.isCancelled else {
            return .cancelled(.ticketReceived, ticket: identity)
        }

        let request: URLRequest
        do {
            request = try Self.storageRequest(ticket: ticket, kind: kind,
                                              expectedProjectID: projectID)
        } catch {
            return .failed(Self.localFailureMessage(error), phase: .ticketReceived,
                           ticket: identity)
        }

        if let fileURL {
            do {
                try Self.verifyFileUnchanged(fileURL, expected: prepared)
            } catch {
                return .failed(Self.localFailureMessage(error), phase: .ticketReceived,
                               ticket: identity)
            }
        }

        if let authorization, !authorization.isCurrent {
            return .cancelled(.ticketReceived, ticket: identity)
        }
        guard !Task.isCancelled else {
            return .cancelled(.ticketReceived, ticket: identity)
        }

        let config = storageConfiguration?.copy() as? URLSessionConfiguration
            ?? URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = kind == .artwork
            ? artworkPutTimeout : filePutTimeout
        // A resource timeout cannot outlive the per-request deadline by much.
        config.timeoutIntervalForResource = kind == .artwork
            ? artworkPutTimeout : filePutTimeout
        let delegate = UploadDelegate { sent, total in
            guard total > 0 else { return }
            progress?(min(max(Double(sent) / Double(total), 0), 1))
        }
        // Separate storage session: no Authorization header or account cookies.
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        progress?(0)
        do {
            let (_, response): (Data, URLResponse)
            if let fileURL {
                (_, response) = try await session.upload(for: request, fromFile: fileURL)
            } else {
                (_, response) = try await session.upload(for: request, from: data ?? Data())
            }
            // Deliberately do not check Task.isCancelled here. Once the storage
            // service returned a success response, that submission is confirmed
            // and a cancellation racing it must not erase the success.
            guard let http = response as? HTTPURLResponse else {
                return .uncertain(
                    "Samply's storage service returned an unreadable response. The upload may have completed.",
                    phase: .putStarted, ticket: identity)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(
                    "Samply's storage service rejected the upload (HTTP \(http.statusCode)). Check the project before retrying.",
                    phase: .putStarted, ticket: identity)
            }
            return .submitted(identity)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return .cancelled(.putStarted, ticket: identity)
            }
            if let urlError = error as? URLError, urlError.code == .timedOut {
                return .uncertain(
                    "The upload timed out after submission started. Samply may have received the file; check the project before trying again.",
                    phase: .putStarted, ticket: identity)
            }
            return .uncertain(
                "The upload was interrupted after submission started. Samply may have received the file; check the project before trying again.",
                phase: .putStarted, ticket: identity)
        }
    }

    private struct PreparedUpload {
        let mimeType: String
        let size: Int64
        let modificationDate: Date?
    }

    private func prepare(kind: UploadKind, fileURL: URL?, data: Data?,
                         mimeType: String?, size: Int64?,
                         fileName: String) throws -> PreparedUpload {
        switch kind {
        case .artwork:
            guard let data, !data.isEmpty,
                  let mimeType, mimeType.lowercased().hasPrefix("image/") else {
                throw SamplyError.fileChanged
            }
            return PreparedUpload(mimeType: mimeType, size: Int64(data.count),
                                  modificationDate: nil)
        case .originalFile:
            guard let fileURL else { throw SamplyError.fileChanged }
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
                throw SamplyError.fileChanged
            }
            let mime = mimeType ?? UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            return PreparedUpload(mimeType: mime, size: size,
                                  modificationDate: attributes[.modificationDate] as? Date)
        }
    }

    private static func verifyFileUnchanged(_ url: URL, expected: PreparedUpload) throws {
        let updated = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (updated[.size] as? NSNumber)?.int64Value == expected.size,
              updated[.modificationDate] as? Date == expected.modificationDate else {
            throw SamplyError.fileChanged
        }
    }

    private static func ticketFailure(_ error: Error) -> UploadOutcome {
        if let samply = error as? SamplyError {
            switch samply {
            case .invalidToken:
                return .failed("Your Samply token is invalid or expired. Update it in Settings > API Access.",
                               phase: .waiting)
            case .noToken:
                return .failed("Add a Samply Personal Access Token in Settings > API Access.",
                               phase: .waiting)
            case .http(let code, _) where code == 408 || (500...599).contains(code):
                return .uncertain(
                    "Samply did not confirm whether it created an upload ticket. Check the project before requesting another upload.",
                    phase: .ticketRequested)
            case .http(let code, _):
                return .failed("Samply rejected the upload request (HTTP \(code)).",
                               phase: .waiting)
            case .invalidResponse:
                return .uncertain(
                    "Samply's upload-ticket response could not be read. Check the project before requesting another upload.",
                    phase: .ticketRequested)
            default:
                return .failed(samply.localizedDescription, phase: .waiting)
            }
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .uncertain(
                "The upload-ticket request was interrupted. Samply may have created a ticket; check the project before requesting another upload.",
                phase: .ticketRequested)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .secureConnectionFailed,
                 .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return .failed("Samply could not be reached. Check your connection and try again.",
                               phase: .waiting)
            default:
                return .uncertain(
                    "The upload-ticket request was interrupted. Samply may have created a ticket; check the project before requesting another upload.",
                    phase: .ticketRequested)
            }
        }
        return .uncertain(
            "Samply did not confirm the upload ticket. Check the project before requesting another upload.",
            phase: .ticketRequested)
    }

    private static func localFailureMessage(_ error: Error) -> String {
        if let samply = error as? SamplyError {
            switch samply {
            case .fileChanged:
                return "The selected file changed or became unavailable before upload."
            case .invalidResponse:
                return "Samply returned incomplete upload metadata. Nothing was uploaded."
            default:
                return samply.localizedDescription
            }
        }
        return "The upload could not be prepared. Nothing was uploaded."
    }

    private static func message(for outcome: UploadOutcome) -> String {
        switch outcome.disposition {
        case .uncertain(let message):
            return message
        case .cancelled, .failed, .submitted:
            return "The upload was interrupted after it may have reached Samply. Check the project before trying again."
        }
    }

    static func storageRequest(ticket: UploadTicket) throws -> URLRequest {
        try storageRequest(ticket: ticket, kind: .originalFile)
    }

    static func storageRequest(ticket: UploadTicket, kind: UploadKind,
                               expectedProjectID: String? = nil) throws -> URLRequest {
        guard !ticket.boxid.isEmpty, ticket.url.scheme == "https", ticket.url.host != nil,
              ticket.url.user == nil, ticket.url.password == nil else {
            throw SamplyError.insecureURL
        }
        let contentType = ticket.contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contentType.isEmpty, !contentType.contains("\r"), !contentType.contains("\n") else {
            throw SamplyError.invalidResponse
        }
        if kind == .artwork, !contentType.lowercased().hasPrefix("image/") {
            throw SamplyError.invalidResponse
        }
        var required = ["destination", "projectid", "boxpath"]
        if kind == .artwork { required.append("writeback") }
        var metadata: [String: String] = [:]
        for key in required {
            guard let value = ticket.metadata[key],
                  !value.isEmpty, !value.contains("\r"), !value.contains("\n") else {
                throw SamplyError.invalidResponse
            }
            if key == "projectid", let expectedProjectID, value != expectedProjectID {
                throw SamplyError.invalidResponse
            }
            metadata[key] = value
        }
        var request = URLRequest(url: ticket.url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for key in required {
            request.setValue(metadata[key], forHTTPHeaderField: "x-goog-meta-\(key)")
        }
        return request
    }
}

private final class UploadDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated let progress: @MainActor @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @MainActor @Sendable (Int64, Int64) -> Void) { self.progress = progress }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                               totalBytesExpectedToSend: Int64) {
        Task { @MainActor in progress(totalBytesSent, totalBytesExpectedToSend) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest,
                               completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
