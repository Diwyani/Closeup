import Foundation

/// A title or note shown over the video for a stretch of time.
struct TextOverlay: Codable, Equatable, Sendable, Identifiable {
    enum Position: String, Codable, CaseIterable, Sendable {
        case top, center, bottom
    }

    var id = UUID()
    var start: Double
    var end: Double
    var text = "Your text"
    var position = Position.top
    /// Multiplier on the text size.
    var size = 1.0
    /// A dark box behind the text instead of a shadow.
    var hasBackground = false

    /// Fade in and out over this long.
    static let fade = 0.25

    func opacity(at time: Double) -> Double {
        guard time >= start, time < end else { return 0 }
        return min(1, (time - start) / Self.fade, (end - time) / Self.fade)
    }
}
