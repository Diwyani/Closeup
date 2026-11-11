import Foundation

/// How a title or the captions look: the box behind the text, its colour
/// and how bold it is.
struct TextLook: Codable, Equatable, Sendable {
    enum Box: String, Codable, CaseIterable, Sendable {
        /// Blurs whatever is behind it, like macOS menus.
        case glass, dark, light, custom, none

        var title: String {
            switch self {
            case .glass: "Glass"
            case .dark: "Dark"
            case .light: "Light"
            case .custom: "Colour"
            case .none: "None"
            }
        }
    }

    enum Weight: String, Codable, CaseIterable, Sendable {
        case regular, semibold, bold
    }

    var box = Box.glass
    /// For a custom box, and the tint of the glass.
    var boxColor = RGBAColor(hex: 0x000000)
    /// 0 = clear, 1 = solid.
    var boxOpacity = 0.35
    /// Pick white or black text, whichever reads better on what's behind it.
    var autoColor = true
    var textColor = RGBAColor(hex: 0xFFFFFF)
    var weight = Weight.semibold

    init(box: Box = .glass, boxOpacity: Double = 0.35, weight: Weight = .semibold) {
        self.box = box
        self.boxOpacity = boxOpacity
        self.weight = weight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextLook()
        box = try c.decodeIfPresent(Box.self, forKey: .box) ?? d.box
        boxColor = try c.decodeIfPresent(RGBAColor.self, forKey: .boxColor) ?? d.boxColor
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? d.boxOpacity
        autoColor = try c.decodeIfPresent(Bool.self, forKey: .autoColor) ?? d.autoColor
        textColor = try c.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? d.textColor
        weight = try c.decodeIfPresent(Weight.self, forKey: .weight) ?? d.weight
    }
}

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
    var look = TextLook(weight: .bold)
    /// Darken the screen while the title shows, like a spotlight.
    var dimsBehind = false
    /// Move to the other edge if the cursor is working near this one.
    var avoidsAction = true

    /// Fade in and out over this long.
    static let fade = 0.25

    init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    func opacity(at time: Double) -> Double {
        guard time >= start, time < end else { return 0 }
        return min(1, (time - start) / Self.fade, (end - time) / Self.fade)
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, text, position, size, look, dimsBehind, avoidsAction, hasBackground
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? "Your text"
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? .top
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
        dimsBehind = try c.decodeIfPresent(Bool.self, forKey: .dimsBehind) ?? false
        avoidsAction = try c.decodeIfPresent(Bool.self, forKey: .avoidsAction) ?? true
        if let look = try c.decodeIfPresent(TextLook.self, forKey: .look) {
            self.look = look
        } else {
            // Titles from before text looks: keep how they looked.
            let hadBox = try c.decodeIfPresent(Bool.self, forKey: .hasBackground) ?? false
            look = TextLook(box: hadBox ? .dark : .none, boxOpacity: 0.72, weight: .bold)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(text, forKey: .text)
        try c.encode(position, forKey: .position)
        try c.encode(size, forKey: .size)
        try c.encode(look, forKey: .look)
        try c.encode(dimsBehind, forKey: .dimsBehind)
        try c.encode(avoidsAction, forKey: .avoidsAction)
    }
}
