import SwiftUI

/// The menu that drops down from the menu bar icon.
struct MenuBarMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button(appState.recordActionTitle) { appState.toggleRecording() }
            .disabled(appState.phase == .saving)
        Text("Shortcut: \(GlobalHotKey.toggleRecordingDisplay)")

        Divider()

        Button("Open Closeup") { appState.showMainWindow() }
        Button("Show Recordings in Finder") { appState.revealLibrary() }
        Button("Check for Updates") {
            appState.showMainWindow()
            Task { await appState.updates.check(manually: true) }
        }

        Divider()

        Button("Quit Closeup") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The icon in the menu bar.
///
/// Keep this static: a live timer here makes SwiftUI rebuild the status item
/// non-stop, which keeps the main thread 100% busy (and froze Stop).
struct MenuBarLabel: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch appState.phase {
            case .recording:
                Image(systemName: "stop.circle.fill")
            case .countdown(let number):
                Image(systemName: "\(number).circle.fill")
            case .idle, .saving:
                Image(systemName: "record.circle")
            }
        }
        .onAppear {
            // This label lives as long as the app, so it's a reliable place to
            // hand AppState a way to open the main window.
            appState.openMainWindow = { openWindow(id: AppState.mainWindowID) }
        }
    }
}
