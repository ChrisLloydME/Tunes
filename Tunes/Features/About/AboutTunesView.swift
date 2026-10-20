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

struct AboutTunesView: View {
    @State private var presentedPage: AboutPage?

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
                        section("Independent Samply Client", text: "Tunes is an independent app by Christopher Lloyd. It is not affiliated with, endorsed by, or supported by Samply. Samply owns its service and trademarks; your audio and other content remain subject to their owners' rights.")
                        section("Service Compatibility", text: "Tunes uses Samply's web player for streaming and an adapter to read library information and operate playback through the website's internal interfaces. These interfaces are not a supported public integration contract and may change or stop working without notice. Tunes has no registered Samply OAuth client or confirmed approval for this web integration.")
                        section("Using Samply with Tunes", text: "Samply's Acceptable Use Policy restricts access through interfaces it does not publicly support, and its Terms restrict reverse engineering except where prohibited by law. Tunes' use of internal web interfaces may conflict with these restrictions. Signing in does not establish Samply's approval. Samply may restrict access or suspend or terminate an account for policy violations. Use Samply's official app or website if you need a supported connection.")
                        section("Your Content and Permissions", text: "Use only accounts and content you are authorized to access, and upload only files you have the right to send to Samply. Tunes does not grant additional access, change sharing or version permissions, or use original-file downloads as a streaming fallback. Creating an empty project uses Samply's documented POST /projects side effect, which also creates a project-scoped player with your default player options. Your Samply plan, service limits, and content permissions still apply.")
                        Link("Samply Terms of Service", destination: URL(string: "https://samply.app/terms")!)
                        Link("Samply Acceptable Use Policy", destination: URL(string: "https://samply.app/acceptable-use")!)
                        Link("Official Samply Apps", destination: URL(string: "https://docs.samply.app/applications.html")!)

                    case .privacy:
                        section("Your Data in Tunes", text: "Tunes connects directly from your Mac to Samply and the services used by its website. Tunes does not operate a server to receive your library, audio, or credentials, and includes no developer analytics, advertising, or crash-reporting service. This does not prevent Samply's website or macOS from collecting information under their own policies and settings.")
                        section("Samply and Other Providers", text: "Sign-in, library browsing, streaming, project creation, artwork assignment, and uploads send requests to Samply and its service providers. They receive network information such as your IP address and may process account details, content, device information, cookies, and usage activity. Samply may record listening activity and make information available to content owners or collaborators. Using Tunes does not make listening anonymous or disable Samply's tracking. Samply's privacy policy governs its processing, retention, and international transfers.")
                        Link("Samply Privacy Policy", destination: URL(string: "https://samply.app/privacy")!)
                        section("What Stays on This Mac", text: "WebKit saves cookies, sign-in state, website storage, and caches to keep your Samply session working. A saved session can reconnect when Tunes starts; the web player can remain connected while its window is hidden. Tunes also saves your account identifier, display name, avatar URL and downloaded avatar, plus a sign-in status flag, in local app preferences. Library and playback information are held in memory; WebKit may separately cache website and media data. Artwork and avatar requests contact the image hosts supplied by Samply, which may be third parties. Local profile and website data are not an encrypted vault and may be included in system backups.")
                        section("Optional API Token", text: "Browsing and playback do not require a personal access token. If you create projects or upload files, Tunes validates the token by requesting its accessible project list, then stores it with the current web account identifier in a plaintext file inside this app's container. Project creation sends only a project name to Samply's official POST /projects endpoint. The directory uses owner-only permissions (0700), the file uses owner-only permissions (0600), and both are excluded from system backups. Tunes does not access Keychain or put tokens in preferences, logs, or JavaScript. File permissions do not protect the token from malware, an administrator, or someone able to read your account's files. Samply tokens can carry privileges beyond creating projects and uploading; treat yours like a password.")
                        section("Sign-In Links", text: "A pasted email sign-in link opens unchanged in the app's existing WebKit session, including any email-provider redirects. Tunes does not check the link's destination or save it in app settings or logs. Only paste a link from the Samply email you requested: an untrusted link can open another website. The destination and redirect providers receive the request, and WebKit may retain website data. The original email and clipboard remain outside Tunes' control.")
                        section("Project Artwork and Original-File Uploads", text: "Assigning artwork sends the prepared image through Samply's authorized web upload path and asks Samply to update the project artwork. It is not sent as an ordinary visible project file and does not use the REST artwork field, which Samply documents as read-only. Uploading an original file sends your chosen file, its filename, type, size, and destination project or folder to Samply and its designated storage service. Embedded metadata stays in the original file. Tunes does not transcode or strip metadata. Existing project access rules determine who can access the upload. Canceling an upload may leave a pending entry or data already received by Samply; check the project in Samply to remove unwanted content.")
                        section("Playback on Your Mac", text: "Tunes sends track title, artist, album, duration, playback position, and playback status to macOS Now Playing for system playback controls and media keys. These details can appear on system surfaces or in screen sharing. Album artwork is cached in memory and can remain until it is evicted or Tunes quits.")
                        section("Signing Out and Removing Data", text: "Signing out clears this build's WebKit website data, cached profile, active library and playback state, and saved personal access token. A signed-out status flag remains in local preferences. If a token file cannot be deleted, Tunes reports an error and deactivates the token in the app. Removing a personal access token also deletes its local file. Local deletion does not revoke the token at Samply, erase backups or clipboard contents, end sessions in other apps, or delete server-side content and activity. Revoke a token in Samply's API preferences if it is no longer needed or may have been exposed; use Samply to manage content, account deletion, and privacy requests.")
                        Link("Manage Samply API Tokens", destination: URL(string: "https://samply.app/preferences/api")!)
                        section("Separate App Sessions", text: "Debug and Release builds keep separate app storage, tokens, and WebKit sessions. Signing out of one build does not sign out of the other or your browser. A saved token is restored only for the same web account identifier and is deleted when Tunes detects a different account. Use a token from that same Samply account; Tunes' project-list validation does not independently prove who owns the token.")
                        section("Release Notes and Links", text: "Opening Release Notes requests public release information from GitHub. GitHub receives your IP address and standard request details, but Tunes sends no Samply credentials, library data, or audio with this request. Release notes load on demand without a persistent cache; opening About alone does not check for updates. External links open in your default browser, where the destination's privacy policy applies.")
                        Link("GitHub Privacy Statement", destination: URL(string: "https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement")!)
                        section("Sharing Support Information", text: "Screenshots, copied errors, and macOS diagnostic reports may contain account details, project or track names, URLs, or other private information. Debug builds also enable Web Inspector, whose output can expose page and session data. Review and redact anything you choose to share. Never include access tokens or email sign-in links in a support request.")
                        Text("Privacy information updated October 20, 2026.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
