import SwiftUI

@main
struct CloseupApp: App {
    // One shared brain: the window, the menu bar and the global hotkey all
    // talk to the same AppState.
    @State private var appState = AppState()

    var body: some Scene {
        Window("Closeup", id: AppState.mainWindowID) {
            MainWindowView()
                .environment(appState)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarMenu()
                .environment(appState)
        } label: {
            MenuBarLabel(appState: appState)
        }
    }
}
