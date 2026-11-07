import CoreGraphics
import Foundation

/// A stretch of time where the camera zooms in. Kept as plain data so the
/// future timeline editor can move, resize, add and remove them.
struct ZoomSegment: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    /// 2 = twice as close.
    var scale: Double
}

/// Something worth zooming in on: a click, or typing.
struct ZoomActivity: Sendable {
    let time: Double
    /// Points from the top-left of the captured area.
    let focus: CGPoint
    let isTyping: Bool
}

/// Decides when to zoom, from what you did while recording.
enum ZoomPlanner {
    static let lead = 0.5      // start zooming this long before the first action
    static let hold = 1.5      // stay zoomed this long after the last action
    static let idleGap = 3.0   // actions closer than this keep one zoom going
    static let mergeGap = 1.0  // zooms closer than this join (no quick out-and-in)

    /// Clicks, plus typing if wanted. Typing focuses on where you last
    /// clicked (usually the text field), since the mouse often wanders off.
    static func activities(from log: CursorLog, duration: Double, includeTyping: Bool) -> [ZoomActivity] {
        var activities: [ZoomActivity] = []
        var lastClick: (time: Double, point: CGPoint)?

        for event in log.events {
            let point = CGPoint(x: event.x, y: event.y)
            if event.isClick {
                lastClick = (event.t, point)
                activities.append(ZoomActivity(time: event.t, focus: point, isTyping: false))
            } else if event.type == .typing, includeTyping,
                      event.t < duration - 1 {  // skip the stop shortcut at the very end
                let focus = lastClick.flatMap { event.t - $0.time < 10 ? $0.point : nil } ?? point
                activities.append(ZoomActivity(time: event.t, focus: focus, isTyping: true))
            }
        }
        return activities
    }

    /// One zoom per burst of activity: it begins just before the first
    /// action and ends a moment after the last.
    static func segments(for activities: [ZoomActivity], duration: Double, scale: Double) -> [ZoomSegment] {
        var segments: [ZoomSegment] = []
        var lastActivity = -Double.infinity

        for activity in activities.sorted(by: { $0.time < $1.time }) {
            let end = min(duration, activity.time + hold)
            if !segments.isEmpty, activity.time - lastActivity <= idleGap
                || activity.time - lead <= segments[segments.count - 1].end + mergeGap {
                segments[segments.count - 1].end = max(segments[segments.count - 1].end, end)
            } else {
                segments.append(ZoomSegment(start: max(0, activity.time - lead), end: end, scale: scale))
            }
            lastActivity = activity.time
        }
        return segments
    }
}

/// Where a virtual camera looks at every moment: how far it's zoomed in and
/// which point it's centred on.
///
/// - Zoom eases in and out with a critically damped spring (smooth, no wobble).
/// - While zoomed, the camera only pans when what you're doing gets near the
///   edge of the view (a "dead zone"), instead of chasing every mouse wiggle.
/// - While typing, it looks at where you're typing, not where the mouse is.
///
/// Simulated once, 120× a second, then looked up.
struct CameraTrack: Sendable {
    static let sampleRate = 120.0
    /// The middle part of the view (as a fraction) where the cursor can move
    /// without the camera following.
    static let deadZone = 0.55

    private let zooms: [Double]
    /// Points from the top-left of the captured area.
    private let centers: [CGPoint]

    /// `speed` 1 = normal; 2 = twice as fast.
    init(
        segments: [ZoomSegment], activities: [ZoomActivity], cursor: CursorTrack,
        screenSize: CGSize, duration: Double, speed: Double
    ) {
        let count = max(1, Int((duration * Self.sampleRate).rounded(.up)) + 1)
        let dt = 1 / Self.sampleRate
        let zoomStiffness = 2 * Double.pi * 0.9 * speed
        let panStiffness = 2 * Double.pi * 0.8 * speed
        let typing = activities.filter(\.isTyping).sorted { $0.time < $1.time }

        var zoom = 1.0
        var zoomVelocity = 0.0
        var center = Self.clamped(cursor.position(at: 0), to: screenSize)
        var centerVelocity = CGPoint.zero
        var segmentIndex = 0
        var typingIndex = 0

        var zooms: [Double] = []
        var centers: [CGPoint] = []
        zooms.reserveCapacity(count)
        centers.reserveCapacity(count)

        for i in 0..<count {
            let t = Double(i) * dt

            // Zoom target: inside a segment or not.
            while segmentIndex < segments.count, segments[segmentIndex].end < t { segmentIndex += 1 }
            let targetZoom = segmentIndex < segments.count && segments[segmentIndex].start <= t
                ? segments[segmentIndex].scale : 1

            // What to look at: where you're typing (if you typed in the last
            // second), otherwise the cursor.
            while typingIndex + 1 < typing.count, typing[typingIndex + 1].time <= t { typingIndex += 1 }
            let recentTyping = typing.indices.contains(typingIndex)
                && typing[typingIndex].time <= t && t - typing[typingIndex].time < 1
            let focus = Self.clamped(recentTyping ? typing[typingIndex].focus : cursor.position(at: t), to: screenSize)

            // Pan target. Zoomed out: just follow (nothing visible moves anyway,
            // and it means a zoom starts right where you are). Zoomed in: only
            // move when the focus leaves the calm middle of the view.
            var target = focus
            if targetZoom > 1, zoom > 1.05 {
                let halfWidth = screenSize.width / zoom / 2
                let halfHeight = screenSize.height / zoom / 2
                target = CGPoint(
                    x: Self.deadZoneTarget(center.x, focus: focus.x, half: halfWidth * Self.deadZone),
                    y: Self.deadZoneTarget(center.y, focus: focus.y, half: halfHeight * Self.deadZone))
                // Never aim past the screen's edge; the view would just stop there anyway.
                target.x = min(max(target.x, halfWidth), screenSize.width - halfWidth)
                target.y = min(max(target.y, halfHeight), screenSize.height - halfHeight)
            }

            zoomVelocity += Self.springAcceleration(zoom, toward: targetZoom, velocity: zoomVelocity, stiffness: zoomStiffness) * dt
            zoom += zoomVelocity * dt
            centerVelocity.x += Self.springAcceleration(center.x, toward: target.x, velocity: centerVelocity.x, stiffness: panStiffness) * dt
            centerVelocity.y += Self.springAcceleration(center.y, toward: target.y, velocity: centerVelocity.y, stiffness: panStiffness) * dt
            center.x += centerVelocity.x * dt
            center.y += centerVelocity.y * dt

            zooms.append(zoom)
            centers.append(center)
        }
        self.zooms = zooms
        self.centers = centers
    }

    func camera(at time: Double) -> (zoom: Double, center: CGPoint) {
        let x = max(0, time * Self.sampleRate)
        let i = min(Int(x), zooms.count - 1)
        let j = min(i + 1, zooms.count - 1)
        let f = min(1, x - Double(i))
        return (
            zooms[i] + (zooms[j] - zooms[i]) * f,
            CGPoint(
                x: centers[i].x + (centers[j].x - centers[i].x) * f,
                y: centers[i].y + (centers[j].y - centers[i].y) * f))
    }

    /// Stay put while `focus` is within `half` of `center`; otherwise move
    /// just enough to bring it back to the edge of that calm zone.
    private static func deadZoneTarget(_ center: Double, focus: Double, half: Double) -> Double {
        if focus > center + half { return focus - half }
        if focus < center - half { return focus + half }
        return center
    }

    /// A critically damped spring: pulls toward the target as fast as
    /// possible without overshooting.
    private static func springAcceleration(_ value: Double, toward target: Double, velocity: Double, stiffness: Double) -> Double {
        stiffness * stiffness * (target - value) - 2 * stiffness * velocity
    }

    private static func clamped(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
    }
}
