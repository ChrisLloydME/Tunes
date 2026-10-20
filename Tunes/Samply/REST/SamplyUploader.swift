import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class SamplyUploader {
    enum Status: Equatable {
        case idle, preparing, uploading, completed, cancelled, failed(String)
    }
    private(set) var status: Status = .idle
    private(set) var progress: Double = 0
    private(set) var fileName = ""
    private(set) var uploadedBoxID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private let api: SamplyAPI
    @ObservationIgnored private let storageConfiguration: URLSessionConfiguration?

    var isRunning: Bool { status == .preparing || status == .uploading }

    init(api: SamplyAPI, storageConfiguration: URLSessionConfiguration? = nil) {
        self.api = api
        self.storageConfiguration = storageConfiguration
    }

    /// The original file is streamed from disk; no transcoding or full-file Data allocation.
    func upload(file: URL, projectID: String, parentID: String? = nil) {
        guard !isRunning else { return }
        let id = UUID()
        operationID = id
        status = .preparing
        progress = 0
        fileName = file.lastPathComponent
        uploadedBoxID = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard !Task.isCancelled, self.operationID == id else { return }
                // The ticket request is part of preparing the upload, but the
                // visible progress lane starts once the streamed PUT can report.
                self.status = .uploading
                let boxID = try await self.performUpload(file: file, projectID: projectID,
                                                         parentID: parentID) { [weak self] value in
                    guard let self, self.operationID == id, self.status == .uploading else { return }
                    self.progress = max(self.progress, min(max(value, 0), 1))
                }
                try Task.checkCancellation()
                guard self.operationID == id else { return }
                self.progress = 1
                self.uploadedBoxID = boxID
                self.status = .completed
            } catch is CancellationError {
                if self.operationID == id { self.status = .cancelled }
            } catch {
                guard self.operationID == id else { return }
                if Task.isCancelled { self.status = .cancelled }
                else { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    /// Awaitable upload used by explicit queues. It shares the same ticket,
    /// streamed PUT, file checks, and storage-session isolation as the album flow
    /// without changing the single visible upload status.
    func performUpload(file: URL, projectID: String, parentID: String? = nil,
                       progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        try Task.checkCancellation()
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
            throw SamplyError.fileChanged
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        try Task.checkCancellation()
        let ticket = try await api.uploadTicket(projectID: projectID, name: file.lastPathComponent,
                                                mimeType: mime, size: size, parentID: parentID)
        try Task.checkCancellation()
        let updated = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (updated[.size] as? NSNumber)?.int64Value == size,
              updated[.modificationDate] as? Date == attributes[.modificationDate] as? Date else {
            throw SamplyError.fileChanged
        }
        let request = try Self.storageRequest(ticket: ticket)
        progress(0)
        let delegate = UploadDelegate { sent, total in
            guard total > 0 else { return }
            progress(min(max(Double(sent) / Double(total), 0), 1))
        }
        let config = storageConfiguration?.copy() as? URLSessionConfiguration
            ?? URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 60 * 60
        // Separate storage session: no Authorization header or account cookies.
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.upload(for: request, fromFile: file)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw SamplyError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw SamplyError.http(response.statusCode, retryAfter: nil)
        }
        return ticket.boxid
    }

    func cancel() {
        task?.cancel()
        operationID = UUID()
        if isRunning { status = .cancelled }
    }

    func reset() {
        cancel()
        status = .idle
        progress = 0
        fileName = ""
        uploadedBoxID = nil
    }

    static func storageRequest(ticket: UploadTicket) throws -> URLRequest {
        guard ticket.url.scheme == "https", ticket.url.host != nil,
              ticket.url.user == nil, ticket.url.password == nil else { throw SamplyError.insecureURL }
        var request = URLRequest(url: ticket.url)
        request.httpMethod = "PUT"
        request.setValue(ticket.contentType, forHTTPHeaderField: "Content-Type")
        for key in ["destination", "projectid", "boxpath"] {
            guard let value = ticket.metadata[key], !value.contains("\r"), !value.contains("\n") else {
                throw SamplyError.invalidResponse
            }
            request.setValue(value, forHTTPHeaderField: "x-goog-meta-\(key)")
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
