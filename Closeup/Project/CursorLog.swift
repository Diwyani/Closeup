import Foundation

/// Everything the mouse did during a recording. Saved as cursor.json.
///
/// How to place an event on the raw video:
///     pixelX = event.x * scale
///     pixelY = event.y * scale      (y grows downwards, like the video)
///
/// Positions can fall outside 0…width / 0…height. That means the cursor was
/// off the recorded area (on another display, or outside the window).
struct CursorLog: Codable {
    var version = 1
    /// Video pixels per point. Constant for the whole recording, so it's stored
    /// once here instead of on every event.
    var scale: Double
    /// Size of the captured area, in points.
    var width: Double
    var height: Double
    /// Cursor shapes seen while recording (I-beam, pointing hand, an app's
    /// tool cursor…), saved as PNGs in the project's cursors/ folder.
    /// Shape 0 is the standard arrow, which we draw ourselves, so it isn't listed.
    var shapes: [CursorShape]?
    var events: [CursorEvent]
}

extension CursorLog {
    /// Re-times raw events so t = 0 is the first video frame.
    /// Events before the first frame collapse into one starting position and shape.
    static func videoTimeline(
        _ raw: [CursorLogger.RawEvent], videoStart: Double, videoEnd: Double
    ) -> [CursorEvent] {
        var events: [CursorEvent] = []
        var positionAtStart: CGPoint?
        var shapeAtStart: Int?

        for event in raw {
            let t = event.hostTime - videoStart
            if t < 0 {
                positionAtStart = event.position
                if let shape = event.shape { shapeAtStart = shape }
                continue
            }
            if event.hostTime > videoEnd { break }
            events.append(CursorEvent(
                t: t, x: event.position.x, y: event.position.y, type: event.type, shape: event.shape))
        }

        var start: [CursorEvent] = []
        if let position = positionAtStart {
            start.append(CursorEvent(t: 0, x: position.x, y: position.y, type: .move))
            if let shape = shapeAtStart {
                start.append(CursorEvent(t: 0, x: position.x, y: position.y, type: .shape, shape: shape))
            }
        }
        return start + events
    }
}

struct CursorShape: Codable, Equatable {
    var id: Int
    /// File name inside cursors/.
    var file: String
    /// Size in points.
    var width: Double
    var height: Double
    /// The click point, in points from the image's top-left.
    var hotspotX: Double
    var hotspotY: Double
}

struct CursorEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case move           // includes drags; button state follows from down/up events
        case leftDown, leftUp
        case rightDown, rightUp
        case otherDown, otherUp
        case shape          // the cursor changed shape; see `shape`
        case typing         // keys were pressed since the last check (which keys is never recorded)
    }

    /// Seconds since the first video frame. Same timeline as the video.
    var t: Double
    /// Points from the top-left of the captured area.
    var x: Double
    var y: Double
    var type: Kind
    /// For `.shape` events: the new CursorShape id (0 = arrow).
    var shape: Int?

    init(t: Double, x: Double, y: Double, type: Kind, shape: Int? = nil) {
        // Rounded so the JSON stays readable; 0.1 ms and 1/100 pt are far
        // finer than anything we can see.
        self.t = (t * 10_000).rounded() / 10_000
        self.x = (x * 100).rounded() / 100
        self.y = (y * 100).rounded() / 100
        self.type = type
        self.shape = shape
    }

    var isClick: Bool {
        type == .leftDown || type == .rightDown || type == .otherDown
    }
}
