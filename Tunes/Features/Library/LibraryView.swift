import AppKit
import SwiftUI

/// Album card metrics follow Kaset's LibraryView. See Docs/ThirdPartyNotices.md.
struct LibraryView: View {
    let items: [LibraryItem]
    let isOpeningProject: Bool
    let creationNotice: ProjectCreationNotice?
    let retryProjectUploads: () -> Void
    let retryProjectArtwork: () -> Void
    let dismissCreationNotice: () -> Void
    let openProject: (LibraryItem) -> Void
    @State private var query = ""

    private var filteredItems: [LibraryItem] {
        items.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
                ($0.artist?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let creationNotice {
                ProjectCreationNoticeView(
                    notice: creationNotice,
                    retryUploads: retryProjectUploads,
                    retryArtwork: retryProjectArtwork,
                    dismiss: dismissCreationNotice
                )
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
            Group {
                if items.isEmpty {
                    ContentUnavailableView("Your Library Is Empty", systemImage: "square.stack",
                                           description: Text("Your albums will appear here."))
                } else if filteredItems.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 18)],
                                  alignment: .leading, spacing: 24) {
                            ForEach(filteredItems) { item in
                                Button { openProject(item) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ProjectArtwork(artwork: item.artwork, size: 160)
                                        Text(item.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .frame(width: 160, alignment: .topLeading)
                                        Text(item.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "Album")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .frame(width: 160, alignment: .leading)
                                    }
                                    .frame(width: 160, height: 222, alignment: .topLeading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open \(item.name)")
                                .accessibilityIdentifier("libraryProject-\(item.id)")
                                .disabled(isOpeningProject)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, prompt: "Search Library")
    }
}

private struct ProjectCreationNoticeView: View {
    let notice: ProjectCreationNotice
    let retryUploads: () -> Void
    let retryArtwork: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Project Needs Attention")
                    .font(.headline)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if notice.canRetryUploads {
                        Button("Retry Uploads", action: retryUploads)
                            .buttonStyle(.bordered)
                    }
                    if notice.canRetryArtwork {
                        Button("Retry Artwork", action: retryArtwork)
                            .buttonStyle(.bordered)
                    }
                }
            }
            Spacer(minLength: 12)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss project notice")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
        }
    }
}

struct ProjectArtwork: View {
    let artwork: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        AsyncImage(url: artwork.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
                .overlay {
                    Image(systemName: "square.stack")
                        .font(.system(size: size * 0.2))
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}
