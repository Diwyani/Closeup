import AppKit
import ScreenCaptureKit

/// One display or window, resolved into everything a recording needs:
/// what to capture, where it is on screen, and how big the video will be.
struct CaptureTarget {
    typealias Kind = RecordingMetadata.SourceKind

    let kind: Kind
    let name: String
    let filter: SCContentFilter
    /// The captured area when recording starts: points, top-left global coordinates.
    let frame: CGRect
    /// Video pixels per point (2 on Retina, usually 1 on external displays).
    let scale: CGFloat
    let displayID: CGDirectDisplayID?
    let windowID: CGWindowID?

    /// Native resolution. Video encoders want even dimensions, so we round
    /// down by at most one pixel.
    var pixelWidth: Int { Int(frame.width * scale) & ~1 }
    var pixelHeight: Int { Int(frame.height * scale) & ~1 }

    /// `keeping`: our own windows to record anyway (to film Closeup itself).
    static func display(
        _ source: DisplaySource, excluding ownApp: SCRunningApplication?, keeping: [SCWindow] = []
    ) -> CaptureTarget {
        // Excluding our whole app (not just today's windows) also hides windows
        // we open later, like the countdown and the camera preview.
        let filter = SCContentFilter(
            display: source.display,
            excludingApplications: ownApp.map { [$0] } ?? [],
            exceptingWindows: keeping)
        return CaptureTarget(
            kind: .display, name: source.name, filter: filter,
            frame: source.display.frame, scale: CGFloat(filter.pointPixelScale),
            displayID: source.display.displayID, windowID: nil)
    }

    static func window(_ source: WindowSource) -> CaptureTarget {
        // "Desktop independent" = just this window's pixels, even if other
        // windows overlap it.
        let filter = SCContentFilter(desktopIndependentWindow: source.window)
        return CaptureTarget(
            kind: .window, name: "\(source.appName) – \(source.title)", filter: filter,
            frame: source.window.frame, scale: CGFloat(filter.pointPixelScale),
            displayID: nil, windowID: source.window.windowID)
    }

    func streamConfiguration(fps: Int, capturesAudio: Bool = false) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.captureResolution = .best
        // At most `fps` frames per second. ScreenCaptureKit skips frames when
        // nothing on screen changes, which keeps files small.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // The whole idea: record without the system cursor and draw our own later.
        config.showsCursor = false
        // Capture straight in YUV, the format the video encoder works in.
        // With RGB (BGRA) the encoder has to convert every frame first; on a
        // Retina screen that conversion falls behind and frames pile up in memory.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 8
        if kind == .window {
            // We add our own shadow at export, so capture just the window.
            config.ignoreShadowsSingleWindow = true
        }
        if capturesAudio {
            // Everything the Mac plays, except Closeup's own sounds.
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }
        return config
    }

    /// The screen to show the countdown on.
    @MainActor
    var screen: NSScreen? {
        if let displayID {
            return NSScreen.screens.first { $0.displayID == displayID }
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first {
            ScreenGeometry.topLeftRect(fromAppKit: $0.frame).contains(center)
        } ?? NSScreen.main
    }
}
