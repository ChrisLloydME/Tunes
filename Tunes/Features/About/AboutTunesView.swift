import AppKit
import SwiftUI

struct AboutTunesCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Tunes") { openWindow(id: "about") }
        }
    }
}

/// Layout reference: AudioMator's About page from the user-provided archive.
/// Implemented as an independent window with Tunes-specific information.
struct AboutTunesView: View {
    @State private var presentedPage: AboutPage?

    private let repositoryURL = URL(string: "https://github.com/ChrisLloydME/Tunes")!
    private let releasesURL = URL(string: "https://github.com/ChrisLloydME/Tunes/releases")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 34) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 164, height: 164)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tunes")
                            .font(.system(size: 52, weight: .medium))

                        HStack(spacing: 14) {
                            Text("Version \(bundleValue("CFBundleShortVersionString"))")
                                .foregroundStyle(.secondary)
                            Text("Build \(bundleValue("CFBundleVersion"))")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.title3.weight(.semibold))
                    }

                    Text("Copyright © 2026 Christopher Lloyd. Tunes includes third-party open-source software. See Acknowledgements.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Link(destination: repositoryURL) {
                        Label("Tunes on GitHub", systemImage: "link")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .offset(y: -18)

            HStack {
                Spacer(minLength: 0)
                Link(destination: releasesURL) {
                    Label("View Releases…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                Button("Release Notes…") { presentedPage = .releaseNotes }
                Button("Acknowledgements…") { presentedPage = .acknowledgements }
                Button("Privacy…") { presentedPage = .privacy }
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 820, height: 420)
        .sheet(item: $presentedPage) { page in
            AboutInformationSheet(page: page)
        }
    }

    private func bundleValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "Unknown"
    }
}

private enum AboutPage: String, Identifiable {
    case releaseNotes
    case acknowledgements
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .releaseNotes: "Release Notes"
        case .acknowledgements: "Acknowledgements"
        case .privacy: "Privacy"
        }
    }
}

private struct AboutInformationSheet: View {
    let page: AboutPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page.title)
                .font(.title2.weight(.semibold))
                .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch page {
                    case .releaseNotes:
                        ReleaseNotesView()

                    case .acknowledgements:
                        section("Kaset", text: "Tunes adapts Kaset's album browsing and player components. Kaset is released under the MIT License.")
                        Link("Kaset on GitHub", destination: URL(string: "https://github.com/sozercan/kaset")!)
                        Text(kasetLicense)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                        section("About Page Design", text: "The About page layout is inspired by AudioMator by Christopher Lloyd, using the reference archive provided for this project.")
                        section("Samply", text: "Tunes uses Samply for its music library, account sign-in, and streaming. Samply's web player provides authenticated playback.")

                    case .privacy:
                        section("Samply Connection", text: "Tunes connects to Samply to sign in, load your library, and stream audio. Samply's pages and media infrastructure handle these requests and may contact their own service providers.")
                        section("Web Session", text: "The app's WebKit session stores website data to keep you signed in. Debug and Release builds use separate website data stores. Signing out clears the current build's Samply website data.")
                        section("Credentials", text: "Personal access tokens are saved in a local plaintext file with restricted permissions and restored for the same Samply account. Removing a token, signing out, or switching accounts deletes the saved file. Tunes does not access the local Keychain. Pasted email sign-in links are opened in the existing Samply web session and are not saved in app settings or logs.")
                        section("Optional Uploads", text: "When you choose Upload File, Tunes sends the original file to Samply's designated upload service. Tunes does not transcode the file or change Samply's access, download, or version permissions.")
                        section("External Links", text: "GitHub and release links open in your default browser. Opening About does not check for updates or request release information over the network.")
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .frame(width: 580, height: 500)
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var kasetLicense: String {
        guard let url = Bundle.main.url(forResource: "Kaset-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The MIT license text is unavailable in this app bundle. See the Kaset repository for its license."
        }
        return text
    }
}
