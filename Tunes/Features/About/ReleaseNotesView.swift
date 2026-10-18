import SwiftUI

struct ReleaseNotesView: View {
    private enum LoadState {
        case loading, loaded([GitHubReleaseNote]), failed
    }

    @State private var state: LoadState = .loading
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch state {
            case .loading:
                ProgressView("Loading release notes…")
            case .failed:
                Text("Release notes could not be loaded. Check your connection or try again later.")
                    .foregroundStyle(.secondary)
                Button("Try Again") { attempt += 1 }
            case .loaded(let releases):
                if releases.isEmpty {
                    Text("No releases have been published yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(releases) { release in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(release.displayTitle).font(.title3.weight(.semibold))
                            if release.isPrerelease {
                                Text("Pre-release").font(.subheadline).foregroundStyle(.secondary)
                            }
                            if let date = release.publishedAt {
                                Text(date, style: .date).font(.subheadline).foregroundStyle(.secondary)
                            }
                            let body = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if body.isEmpty {
                                Text("No release notes provided.").foregroundStyle(.secondary)
                            } else {
                                // Native text renders inline Markdown without loading remote images or HTML.
                                ForEach(Array(body.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                                    markdownLine(line)
                                }
                            }
                        }
                        if release.id != releases.last?.id { Divider() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: attempt) {
            state = .loading
            do {
                let releases = try await GitHubReleaseNotesClient().fetchReleases()
                try Task.checkCancellation()
                state = .loaded(releases)
            } catch {
                if !Task.isCancelled { state = .failed }
            }
        }
    }

    private func markdownLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        let isHeading = (1...6).contains(hashes) && trimmed.dropFirst(hashes).first == " "
        let content = isHeading ? String(trimmed.dropFirst(hashes + 1)) : line
        let attributed = (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(content)
        return Text(attributed)
            .font(isHeading ? .headline : .body)
            .fixedSize(horizontal: false, vertical: true)
    }
}
