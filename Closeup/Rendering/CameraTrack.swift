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
    /// Where to zoom, chosen by you: 0…1 across and down the screen.
    /// nil = automatic.
    var focus: CGPoint?
    /// Follow the cursor around instead of holding still.
    var followsCursor: Bool?
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

    /// Where a steady zoom looks, in screen points: the middle of everything
    /// you clicked or typed during it, if it all fits in view (with room to
    /// spare). nil = it doesn't fit, so the zoom follows the cursor instead.
    static func steadyCenter(for segment: ZoomSegment, activities: [ZoomActivity], screenSize: CGSize) -> CGPoint? {
        let points = activities.filter { $0.time >= segment.start && $0.time <= segment.end }.map(\.focus)
        guard let first = points.first else { return nil }
        let box = points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        let fitsWidth = box.width <= screenSize.width / segment.scale * 0.8
        let fitsHeight = box.height <= screenSize.height / segment.scale * 0.8
        return fitsWidth && fitsHeight ? CGPoint(x: box.midX, y: box.midY) : nil
    }

    /// The point a zoom holds still on, in screen points; nil if it follows the cursor.
    static func anchor(for segment: ZoomSegment, activities: [ZoomActivity], screenSize: CGSize) -> CGPoint? {
        if segment.followsCursor == true { return nil }
        if let focus = segment.focus {
            return CGPoint(x: focus.x * screenSize.width, y: focus.y * screenSize.height)
        }
        return steadyCenter(for: segment, activities: activities, screenSize: screenSize)
    }

    /// One zoom per burst of activity: it begins just before the first
    /// action and ends a moment after the last.
    /// `scale` is for clicks, `typingScale` for typing (closer, so text is
    /// readable). A zoom with typing in it uses the typing level.
    static func segments(
        for activities: [ZoomActivity], duration: Double, scale: Double, typingScale: Double
    ) -> [ZoomSegment] {
        var segments: [ZoomSegment] = []
        var lastActivity = -Double.infinity

        for activity in activities.sorted(by: { $0.time < $1.time }) {
            let end = min(duration, activity.time + hold)
            let wanted = activity.isTyping ? typingScale : scale
            if !segments.isEmpty, activity.time - lastActivity <= idleGap
                || activity.time - lead <= segments[segments.count - 1].end + mergeGap {
                segments[segments.count - 1].end = max(segments[segments.count - 1].end, end)
                segments[segments.count - 1].scale = max(segments[segments.count - 1].scale, wanted)
            } else {
                segments.append(ZoomSegment(start: max(0, activity.time - lead), end: end, scale: wanted))
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
/// - Each zoom holds still on one spot (yours, or the middle of what you did
///   in it), unless it's set to follow the cursor or your actions don't fit.
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
        let anchors = segments.map { ZoomPlanner.anchor(for: $0, activities: activities, screenSize: screenSize) }

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
            let active = segmentIndex < segments.count && segments[segmentIndex].start <= t ? segmentIndex : nil
            if let active, let anchor = anchors[active] {
                // A steady zoom: hold on its spot, kept inside the screen.
                let halfWidth = screenSize.width / targetZoom / 2
                let halfHeight = screenSize.height / targetZoom / 2
                target = CGPoint(
                    x: min(max(anchor.x, halfWidth), screenSize.width - halfWidth),
                    y: min(max(anchor.y, halfHeight), screenSize.height - halfHeight))
            } else if targetZoom > 1, zoom > 1.05 {
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
