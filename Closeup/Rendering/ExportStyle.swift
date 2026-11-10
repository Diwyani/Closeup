import CoreImage
import Foundation

/// Everything that makes a raw recording look polished. Saved per recording
/// as style.json, so it stays editable.
///
/// Sizes are in pixels on a 1920-wide canvas (1080p). The compositor scales
/// them for other sizes, so a 4K export looks identical, just sharper.
struct ExportStyle: Codable, Equatable, Sendable {
    enum BackgroundKind: String, Codable, CaseIterable, Sendable {
        case gradient, solid, image
    }

    var backgroundKind = BackgroundKind.gradient
    var solidColor = RGBAColor(hex: 0x1C1C1E)
    var gradientStart = GradientPreset.all[0].start
    var gradientEnd = GradientPreset.all[0].end
    /// Like CSS: 0° goes up, 90° goes right, 135° goes to the bottom-right.
    var gradientAngle = 135.0
    /// The picture's file name inside the recording's folder.
    var backgroundImage: String?
    /// 0 = sharp, 1 = very soft.
    var backgroundBlur = 0.4
    /// 0 = as is, 1 = much darker.
    var backgroundDim = 0.0

    var padding = 80.0
    var cornerRadius = 14.0
    /// 0 = no shadow, 1 = strongest.
    var shadow = 0.6

    var showsCursor = true
    /// Multiplier on the real cursor's size.
    var cursorSize = 1.5
    /// 0 = raw movement, 1 = very smooth.
    var cursorSmoothing = 0.5
    /// Fade the cursor out when the mouse sits still.
    var hidesIdleCursor = true
    /// A soft glow on each click.
    var clickEffect = true
    /// Blur the cursor along fast moves.
    var motionBlur = true

    enum Aspect: String, Codable, CaseIterable, Sendable {
        case wide = "16:9", vertical = "9:16", square = "1:1", classic = "4:3"

        /// Width ÷ height.
        var ratio: Double {
            switch self {
            case .wide: 16 / 9
            case .vertical: 9 / 16
            case .square: 1
            case .classic: 4 / 3
            }
        }
    }

    /// Shape of the exported video.
    var aspect = Aspect.wide

    /// Zoom in around clicks, following the cursor.
    var autoZoom = true
    /// How close auto-zoom gets (2 = twice as close).
    var zoomLevel = 2.0
    /// Also zoom in while typing, not just on clicks.
    var zoomOnTyping = true
    /// How close typing zooms: closer than clicks, so small text is readable.
    var typingZoomLevel = 3.0
    /// How quickly the camera zooms and pans (1 = normal).
    var zoomSpeed = 1.0
    /// Zooms edited on the timeline. nil = use the automatic ones.
    var zoomSegments: [ZoomSegment]?

    /// Speed up stretches where nothing happens (automatic edits).
    var speedUpIdle = false
    var idleSpeed = 4.0
    /// Cut short pauses where nothing happens and you're not talking.
    var cutsSilence = false
    /// Pauses at least this long are cut (seconds).
    var silenceLength = 1.5
    /// Cuts and speed-ups edited on the timeline. nil = use the automatic ones.
    var timeEdits: [TimeEdit]?

    /// The part of the recording to keep, in seconds. nil end = to the end.
    var trimStart = 0.0
    var trimEnd: Double?
    /// Trim to just before your first action or word and just after your last.
    var autoTrim = false

    enum Corner: String, Codable, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    enum CameraShape: String, Codable, CaseIterable, Sendable {
        case circle, square, tall, wide

        /// Width ÷ height of the bubble.
        var ratio: Double {
            switch self {
            case .circle, .square: 1
            case .tall: 0.8
            case .wide: 4.0 / 3
            }
        }
    }

    var showsCamera = true
    var cameraShape = CameraShape.circle
    /// Bubble height as a fraction of the video's short side.
    var cameraSize = 0.24
    /// Corner rounding for non-circle bubbles, as a fraction of their short side.
    var cameraRoundness = 0.18
    var cameraCorner = Corner.bottomRight
    /// Like a mirror, which is how people expect to see themselves.
    var cameraMirrored = true

    /// Full-screen camera, side by side, etc. for parts of the video.
    var cameraLayouts: [LayoutSegment] = []

    /// Titles and notes on top of the video.
    var textOverlays: [TextOverlay] = []

    /// Captions made from the microphone. nil = not generated yet.
    var captions: [Caption]?
    var showsCaptions = true
    /// Multiplier on the caption text size.
    var captionSize = 1.0

    /// Use the cleaned-up microphone (noise reduced, even loudness).
    var cleansAudio = false

    /// 1 = as recorded, 0 = muted, up to 2 = twice as loud.
    var microphoneVolume = 1.0
    var systemVolume = 1.0

    init() {}

    /// Reads older style.json files too: any setting that's missing (because
    /// it was added in a later version) gets its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportStyle()
        backgroundKind = try c.decodeIfPresent(BackgroundKind.self, forKey: .backgroundKind) ?? d.backgroundKind
        solidColor = try c.decodeIfPresent(RGBAColor.self, forKey: .solidColor) ?? d.solidColor
        gradientStart = try c.decodeIfPresent(RGBAColor.self, forKey: .gradientStart) ?? d.gradientStart
        gradientEnd = try c.decodeIfPresent(RGBAColor.self, forKey: .gradientEnd) ?? d.gradientEnd
        gradientAngle = try c.decodeIfPresent(Double.self, forKey: .gradientAngle) ?? d.gradientAngle
        backgroundImage = try c.decodeIfPresent(String.self, forKey: .backgroundImage)
        backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? d.backgroundBlur
        backgroundDim = try c.decodeIfPresent(Double.self, forKey: .backgroundDim) ?? d.backgroundDim
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? d.shadow
        showsCursor = try c.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? d.showsCursor
        cursorSize = try c.decodeIfPresent(Double.self, forKey: .cursorSize) ?? d.cursorSize
        cursorSmoothing = try c.decodeIfPresent(Double.self, forKey: .cursorSmoothing) ?? d.cursorSmoothing
        hidesIdleCursor = try c.decodeIfPresent(Bool.self, forKey: .hidesIdleCursor) ?? d.hidesIdleCursor
        clickEffect = try c.decodeIfPresent(Bool.self, forKey: .clickEffect) ?? d.clickEffect
        motionBlur = try c.decodeIfPresent(Bool.self, forKey: .motionBlur) ?? d.motionBlur
        aspect = try c.decodeIfPresent(Aspect.self, forKey: .aspect) ?? d.aspect
        autoZoom = try c.decodeIfPresent(Bool.self, forKey: .autoZoom) ?? d.autoZoom
        zoomLevel = try c.decodeIfPresent(Double.self, forKey: .zoomLevel) ?? d.zoomLevel
        zoomOnTyping = try c.decodeIfPresent(Bool.self, forKey: .zoomOnTyping) ?? d.zoomOnTyping
        typingZoomLevel = try c.decodeIfPresent(Double.self, forKey: .typingZoomLevel) ?? d.typingZoomLevel
        zoomSpeed = try c.decodeIfPresent(Double.self, forKey: .zoomSpeed) ?? d.zoomSpeed
        zoomSegments = try c.decodeIfPresent([ZoomSegment].self, forKey: .zoomSegments)
        speedUpIdle = try c.decodeIfPresent(Bool.self, forKey: .speedUpIdle) ?? d.speedUpIdle
        idleSpeed = try c.decodeIfPresent(Double.self, forKey: .idleSpeed) ?? d.idleSpeed
        cutsSilence = try c.decodeIfPresent(Bool.self, forKey: .cutsSilence) ?? d.cutsSilence
        silenceLength = try c.decodeIfPresent(Double.self, forKey: .silenceLength) ?? d.silenceLength
        timeEdits = try c.decodeIfPresent([TimeEdit].self, forKey: .timeEdits)
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? d.trimStart
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        autoTrim = try c.decodeIfPresent(Bool.self, forKey: .autoTrim) ?? d.autoTrim
        showsCamera = try c.decodeIfPresent(Bool.self, forKey: .showsCamera) ?? d.showsCamera
        cameraShape = try c.decodeIfPresent(CameraShape.self, forKey: .cameraShape) ?? d.cameraShape
        cameraRoundness = try c.decodeIfPresent(Double.self, forKey: .cameraRoundness) ?? d.cameraRoundness
        textOverlays = try c.decodeIfPresent([TextOverlay].self, forKey: .textOverlays) ?? d.textOverlays
        cameraSize = try c.decodeIfPresent(Double.self, forKey: .cameraSize) ?? d.cameraSize
        cameraCorner = try c.decodeIfPresent(Corner.self, forKey: .cameraCorner) ?? d.cameraCorner
        cameraMirrored = try c.decodeIfPresent(Bool.self, forKey: .cameraMirrored) ?? d.cameraMirrored
        cameraLayouts = try c.decodeIfPresent([LayoutSegment].self, forKey: .cameraLayouts) ?? d.cameraLayouts
        captions = try c.decodeIfPresent([Caption].self, forKey: .captions)
        showsCaptions = try c.decodeIfPresent(Bool.self, forKey: .showsCaptions) ?? d.showsCaptions
        captionSize = try c.decodeIfPresent(Double.self, forKey: .captionSize) ?? d.captionSize
        cleansAudio = try c.decodeIfPresent(Bool.self, forKey: .cleansAudio) ?? d.cleansAudio
        microphoneVolume = try c.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? d.microphoneVolume
        systemVolume = try c.decodeIfPresent(Double.self, forKey: .systemVolume) ?? d.systemVolume
    }

    static func load(from url: URL) throws -> ExportStyle {
        try JSONDecoder().decode(ExportStyle.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct RGBAColor: Codable, Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// RGBAColor(hex: 0xFF6A88)
    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    var ciColor: CIColor {
        CIColor(red: r, green: g, blue: b, alpha: a)
    }
}

struct GradientPreset: Identifiable, Sendable {
    let name: String
    let start: RGBAColor
    let end: RGBAColor
    var id: String { name }

    static let all = [
        GradientPreset(name: "Dusk", start: RGBAColor(hex: 0x6E8BFF), end: RGBAColor(hex: 0xC86DD7)),
        GradientPreset(name: "Peach", start: RGBAColor(hex: 0xFF9A8B), end: RGBAColor(hex: 0xFF6A88)),
        GradientPreset(name: "Sunrise", start: RGBAColor(hex: 0xF6D365), end: RGBAColor(hex: 0xFDA085)),
        GradientPreset(name: "Mint", start: RGBAColor(hex: 0x43E97B), end: RGBAColor(hex: 0x38F9D7)),
        GradientPreset(name: "Ocean", start: RGBAColor(hex: 0x2E3192), end: RGBAColor(hex: 0x1BFFFF)),
        GradientPreset(name: "Graphite", start: RGBAColor(hex: 0x434343), end: RGBAColor(hex: 0x0F0F0F)),
    ]
}
