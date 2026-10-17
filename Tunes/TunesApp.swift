import SwiftUI

@main
struct TunesApp: App {
    @State private var backend = SamplyBackend()
    @FocusedValue(\.samplyPage) private var currentPage

    var body: some Scene {
        Window("Tunes", id: "library") {
            ContentView(backend: backend)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            AboutTunesCommands()
            CommandMenu("Samply") {
                Button("Open in Samply") { Task { await backend.openInSamply(currentPage ?? .library) } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(backend.isOpeningSamply || backend.isBrowsing || backend.isPlayingSelection || backend.isRefreshing)
                Button((currentPage ?? .library).refreshLabel) { Task { await backend.refresh(currentPage ?? .library) } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!backend.isConnected || backend.isRefreshing || backend.isBrowsing || backend.isPlayingSelection || backend.isOpeningSamply)
            }
        }
        Window("About Tunes", id: "about") {
            AboutTunesView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        Settings { ConnectionView(backend: backend) }
    }
}
