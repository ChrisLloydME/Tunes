import SwiftUI

@main
struct TunesApp: App {
    @State private var backend = SamplyBackend()

    var body: some Scene {
        Window("Tunes", id: "library") {
            ContentView(backend: backend)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            AboutTunesCommands()
            CommandMenu("Samply") {
                Button("Open Samply Sign-In and Player") { backend.web.showWindow() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Refresh Library") { Task { await backend.refreshLibrary() } }
                    .keyboardShortcut("r", modifiers: .command)
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
