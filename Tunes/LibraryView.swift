import SwiftUI

/// Album card metrics follow Kaset's LibraryView. See Docs/ThirdPartyNotices.md.
struct LibraryView: View {
    let items: [LibraryItem]
    let isOpeningProject: Bool
    let openProject: (LibraryItem) -> Void
    @State private var query = ""

    private var filteredItems: [LibraryItem] {
        items.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
                ($0.artist?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
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
        .searchable(text: $query, prompt: "Search Library")
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
