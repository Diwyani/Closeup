import AppKit

/// Makes quitting safe: a recording in progress is finished and saved first.
///
/// Without this, ⌘Q, the menu's Quit, logging out, restarting, or the updater
/// closing the app all threw the current recording away.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AppState when it starts.
    static weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState = Self.appState, appState.phase != .idle else { return .terminateNow }
        Task {
            await appState.finishBeforeQuitting()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
