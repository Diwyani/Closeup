import AppKit

/// Screen Recording is a privacy permission the user grants in System Settings.
/// There's no Info.plist key for it; macOS asks the first time we request it.
enum ScreenRecordingPermission {
    /// Checks without showing any prompt.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt (only the first time ever; after that macOS
    /// silently returns false and the user has to use System Settings).
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// macOS often only applies a newly granted permission after the app
    /// restarts, so we offer a one-click relaunch.
    @MainActor
    static func relaunchApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
