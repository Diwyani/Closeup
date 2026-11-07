import AppKit
import ScreenCaptureKit

struct DisplaySource: Identifiable {
    let display: SCDisplay
    let name: String
    var id: CGDirectDisplayID { display.displayID }
}

struct WindowSource: Identifiable {
    let window: SCWindow
    let title: String
    let appName: String
    let icon: NSImage?
    var id: CGWindowID { window.windowID }
}

/// Everything the user can pick to record, fetched from ScreenCaptureKit.
struct CaptureSources {
    var displays: [DisplaySource] = []
    var windows: [WindowSource] = []
    /// Our own app, so display recordings can leave Closeup's UI out.
    var ownApplication: SCRunningApplication?

    @MainActor
    static func load() async throws -> CaptureSources {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier

        let displays = content.displays.map { display in
            let screen = NSScreen.screens.first { $0.displayID == display.displayID }
            return DisplaySource(display: display, name: screen?.localizedName ?? "Display \(display.displayID)")
        }

        // Only "real" windows: normal layer, titled, not tiny, not ours.
        let windows = content.windows
            .filter { window in
                window.windowLayer == 0
                    && window.frame.width >= 100 && window.frame.height >= 60
                    && !(window.title ?? "").isEmpty
                    && window.owningApplication?.bundleIdentifier != ownBundleID
            }
            .map { window in
                let app = window.owningApplication
                return WindowSource(
                    window: window,
                    title: window.title ?? "",
                    appName: app?.applicationName ?? "",
                    icon: app.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon })
            }
            .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }

        // Our app is only listed above if one of its windows is on screen right
        // now, so look it up in the full list to always keep our UI out.
        let allContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return CaptureSources(
            displays: displays,
            windows: windows,
            ownApplication: allContent.applications.first { $0.bundleIdentifier == ownBundleID })
    }
}
