import Foundation

/// What was recorded and how. Saved as project.json.
struct RecordingMetadata: Codable {
    enum SourceKind: String, Codable {
        case display, window
    }

    struct Source: Codable {
        var kind: SourceKind
        var name: String
        var displayID: UInt32?
        var windowID: UInt32?
    }

    /// One physical display at recording time. Kept so later phases can reason
    /// about multi-display setups (e.g. the cursor leaving the recorded display).
    struct Display: Codable {
        var id: UInt32
        /// Points, global top-left-origin coordinates.
        var frame: Rect
        var scale: Double
        var isPrimary: Bool
    }

    var version = 1
    var createdAt: Date
    var source: Source

    /// The captured area when recording started, in points, in global
    /// top-left-origin coordinates (0,0 = top-left of the main display).
    var captureFrame: Rect
    /// Video pixels per point (2 on Retina). Same value as `CursorLog.scale`.
    var scale: Double
    var videoWidth: Int
    var videoHeight: Int
    var fps: Int
    /// Seconds, from the first frame to the moment recording was stopped.
    var duration: Double
    var frameCount: Int
    var droppedFrameCount: Int
    var displays: [Display]

    /// An extra file recorded alongside the screen (camera, mic, system audio).
    struct MediaTrack: Codable {
        var file: String
        /// Seconds from the screen video's first frame to this file's start.
        /// Negative means the file started earlier (e.g. the camera warming
        /// up during the countdown); that part is skipped on playback.
        var offset: Double
        var deviceName: String?
    }

    var camera: MediaTrack?
    var microphone: MediaTrack?
    var systemAudio: MediaTrack?
}

/// A CGRect that reads nicely in JSON ({"x":…,"y":…,"width":…,"height":…}).
struct Rect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
