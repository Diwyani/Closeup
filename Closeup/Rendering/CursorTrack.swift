import CoreGraphics
import Foundation

/// The cursor's path, cleaned up and ready to look up at any time.
///
/// Built once from the cursor log:
/// 1. Sample the raw log 120× a second (holding the last known position).
/// 2. Blur those samples over time with a Gaussian. Because the blur looks
///    both backwards and forwards, it removes jitter without making the
///    cursor lag behind (a spring would trail behind your clicks).
struct CursorTrack: Sendable {
    static let sampleRate = 120.0

    /// Points from the top-left of the captured area, one per 1/120 s.
    private let samples: [CGPoint]
    private let clickTimes: [Double]
    private let shapeTimes: [Double]
    private let shapeIDs: [Int]
    private let activityTimes: [Double]

    init(log: CursorLog, duration: Double, smoothing: Double) {
        let count = max(1, Int((duration * Self.sampleRate).rounded(.up)) + 1)
        let events = log.events

        var raw: [CGPoint] = []
        raw.reserveCapacity(count)
        var next = 0
        var current = events.first.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero
        for i in 0..<count {
            let t = Double(i) / Self.sampleRate
            while next < events.count, events[next].t <= t {
                current = CGPoint(x: events[next].x, y: events[next].y)
                next += 1
            }
            raw.append(current)
        }

        // Up to 80 ms of blur at full smoothing.
        samples = Self.smoothed(raw, sigma: smoothing * 0.08 * Self.sampleRate)
        clickTimes = events.filter(\.isClick).map(\.t)

        // When the mouse actually did something (moved a visible amount or clicked).
        var activity: [Double] = []
        var previous: CGPoint?
        for event in events where event.type == .move || event.isClick {
            let point = CGPoint(x: event.x, y: event.y)
            if event.isClick || previous.map({ hypot(point.x - $0.x, point.y - $0.y) > 1 }) ?? true {
                activity.append(event.t)
            }
            previous = point
        }
        activityTimes = activity

        let shapeEvents = events.filter { $0.type == .shape }
        shapeTimes = shapeEvents.map(\.t)
        shapeIDs = shapeEvents.map { $0.shape ?? 0 }
    }

    /// Times of every click (any button).
    var clicks: [Double] { clickTimes }

    /// Smoothed position at `time` seconds, in points from the top-left of the captured area.
    func position(at time: Double) -> CGPoint {
        let x = max(0, time * Self.sampleRate)
        let i = min(Int(x), samples.count - 1)
        let j = min(i + 1, samples.count - 1)
        let f = min(1, x - Double(i))
        return CGPoint(
            x: samples[i].x + (samples[j].x - samples[i].x) * f,
            y: samples[i].y + (samples[j].y - samples[i].y) * f)
    }

    /// 1 right at a click, easing back to 0 over a quarter second. Used for
    /// the little "press" the cursor does when you click.
    func clickAmount(at time: Double) -> Double {
        guard let index = Self.lastIndex(in: clickTimes, atOrBefore: time) else { return 0 }
        let elapsed = time - clickTimes[index]
        let duration = 0.25
        guard elapsed < duration else { return 0 }
        let remaining = 1 - elapsed / duration
        return remaining * remaining
    }

    /// Seconds since the most recent click, if any.
    func timeSinceClick(at time: Double) -> Double? {
        Self.lastIndex(in: clickTimes, atOrBefore: time).map { time - clickTimes[$0] }
    }

    /// 1 while the mouse is in use; fades to 0 once it has been still for 1.5 s.
    func visibility(at time: Double) -> Double {
        guard let index = Self.lastIndex(in: activityTimes, atOrBefore: time) else { return 1 }
        let idle = time - activityTimes[index]
        return idle < 1.5 ? 1 : max(0, 1 - (idle - 1.5) / 0.4)
    }

    /// Which cursor shape is showing at `time` (0 = the arrow).
    func shape(at time: Double) -> Int {
        Self.lastIndex(in: shapeTimes, atOrBefore: time).map { shapeIDs[$0] } ?? 0
    }

    /// Binary search: the last index whose time is ≤ `time`.
    private static func lastIndex(in times: [Double], atOrBefore time: Double) -> Int? {
        var low = 0
        var high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] <= time { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    /// Gaussian blur over time. `sigma` is in samples.
    private static func smoothed(_ points: [CGPoint], sigma: Double) -> [CGPoint] {
        guard sigma >= 0.5, points.count > 1 else { return points }
        let radius = Int((sigma * 3).rounded(.up))
        let weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = weights.reduce(0, +)

        return points.indices.map { i in
            var x = 0.0
            var y = 0.0
            for (k, weight) in weights.enumerated() {
                let j = min(max(i + k - radius, 0), points.count - 1)
                x += points[j].x * weight
                y += points[j].y * weight
            }
            return CGPoint(x: x / total, y: y / total)
        }
    }
}
