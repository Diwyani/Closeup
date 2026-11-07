import AppKit

/// macOS has two global coordinate systems, and mixing them up is the classic
/// multi-display bug:
///
/// - AppKit (NSEvent, NSScreen): origin at the BOTTOM-left of the main display, y goes up.
/// - Core Graphics / ScreenCaptureKit (SCDisplay.frame, SCWindow.frame): origin
///   at the TOP-left of the main display, y goes down.
///
/// Video frames are top-left too, so we convert everything to the Core Graphics
/// system as early as possible and never look back.
@MainActor
enum ScreenGeometry {
    /// The main display (the one with the menu bar) anchors both systems.
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func topLeftPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func topLeftRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The mouse position right now, in top-left global points.
    static var mouseLocation: CGPoint {
        topLeftPoint(fromAppKit: NSEvent.mouseLocation)
    }

    /// Where a window is right now (top-left global points). Windows can move
    /// while being recorded, so the cursor logger asks this repeatedly.
    nonisolated static func currentFrame(ofWindow windowID: CGWindowID) -> CGRect? {
        guard
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
            let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// The whole display layout, for project.json.
    static func displaySnapshot() -> [RecordingMetadata.Display] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = screen.displayID else { return nil }
            return RecordingMetadata.Display(
                id: id,
                frame: Rect(topLeftRect(fromAppKit: screen.frame)),
                scale: screen.backingScaleFactor,
                isPrimary: index == 0)
        }
    }
}

extension NSScreen {
    /// The Core Graphics display ID, which is what ScreenCaptureKit uses.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
