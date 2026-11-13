import CoreImage
import Foundation
import os

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
    /// For gradients with more than two colours (from a preset). nil = just
    /// the start and end colours.
    var gradientStops: [RGBAColor]?
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
    /// Cut "um", "uh" and similar sounds (needs captions).
    var removesFillers = false
    /// Cuts and speed-ups you made or changed on the timeline. Automatic ones
    /// fill in around them.
    var timeEdits: [TimeEdit]?
    /// Automatic edits you deleted or changed, so they don't come back.
    var dismissedEdits: [TimeEdit] = []

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
    /// The layout for the whole video, outside any layout blocks.
    var baseLayout = CameraLayout.bubble

    enum Side: String, Codable, CaseIterable, Sendable { case left, right }

    /// Side by side: where the camera goes (left/right; top/bottom in tall videos).
    var cameraSide = Side.left
    /// Side by side: the camera's share of the width (or height in tall videos).
    var cameraPanelShare = 0.4
    /// Side by side and Camera only: corner rounding of the camera panel, in px at 1080p.
    var cameraPanelRadius = 20.0

    /// Titles and notes on top of the video.
    var textOverlays: [TextOverlay] = []

    /// Captions made from the microphone. nil = not generated yet.
    var captions: [Caption]?
    var showsCaptions = true
    /// Multiplier on the caption text size.
    var captionSize = 1.0
    var captionLook = TextLook(box: .dark, boxOpacity: 0.72, weight: .semibold)
    /// Move captions to the top while the cursor works near the bottom.
    var captionsAvoidAction = true

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
        gradientStops = try c.decodeIfPresent([RGBAColor].self, forKey: .gradientStops)
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
        removesFillers = try c.decodeIfPresent(Bool.self, forKey: .removesFillers) ?? d.removesFillers
        timeEdits = try c.decodeIfPresent([TimeEdit].self, forKey: .timeEdits)
        dismissedEdits = try c.decodeIfPresent([TimeEdit].self, forKey: .dismissedEdits) ?? d.dismissedEdits
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
        baseLayout = try c.decodeIfPresent(CameraLayout.self, forKey: .baseLayout) ?? d.baseLayout
        cameraSide = try c.decodeIfPresent(Side.self, forKey: .cameraSide) ?? d.cameraSide
        cameraPanelShare = try c.decodeIfPresent(Double.self, forKey: .cameraPanelShare) ?? d.cameraPanelShare
        cameraPanelRadius = try c.decodeIfPresent(Double.self, forKey: .cameraPanelRadius) ?? d.cameraPanelRadius
        captions = try c.decodeIfPresent([Caption].self, forKey: .captions)
        showsCaptions = try c.decodeIfPresent(Bool.self, forKey: .showsCaptions) ?? d.showsCaptions
        captionSize = try c.decodeIfPresent(Double.self, forKey: .captionSize) ?? d.captionSize
        captionLook = try c.decodeIfPresent(TextLook.self, forKey: .captionLook) ?? d.captionLook
        captionsAvoidAction = try c.decodeIfPresent(Bool.self, forKey: .captionsAvoidAction) ?? d.captionsAvoidAction
        cleansAudio = try c.decodeIfPresent(Bool.self, forKey: .cleansAudio) ?? d.cleansAudio
        microphoneVolume = try c.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? d.microphoneVolume
        systemVolume = try c.decodeIfPresent(Double.self, forKey: .systemVolume) ?? d.systemVolume
    }

    static func load(from url: URL) throws -> ExportStyle {
        try JSONDecoder().decode(ExportStyle.self, from: Data(contentsOf: url))
    }

    /// The saved settings, or the defaults for a recording never edited.
    ///
    /// A style.json that can't be read (damaged, or written by a newer
    /// Closeup) is set aside as "style (unreadable).json" first. Otherwise
    /// the next change in the editor would overwrite it, and every zoom,
    /// caption and title in it would be gone for good.
    static func loadKeepingUnreadable(from url: URL) -> ExportStyle {
        guard FileManager.default.fileExists(atPath: url.path) else { return ExportStyle() }
        do {
            return try load(from: url)
        } catch {
            let backup = url.deletingLastPathComponent().appending(path: "style (unreadable).json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            Logger.recording.error("Couldn't read \(url.path, privacy: .public), kept a copy: \(String(describing: error), privacy: .public)")
            return ExportStyle()
        }
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
    /// Two or more colours, first to last.
    let stops: [RGBAColor]
    /// Picking a preset sets this angle: diagonal, top-left to bottom-right.
    var angle = 135.0
    var id: String { name }
    var start: RGBAColor { stops[0] }
    var end: RGBAColor { stops[stops.count - 1] }

    init(name: String, start: RGBAColor, end: RGBAColor) {
        self.name = name
        stops = [start, end]
    }

    init(name: String, top stops: [UInt32]) {
        self.name = name
        self.stops = stops.map(RGBAColor.init(hex:))
    }

    static let all = [
        GradientPreset(name: "Dusk", start: RGBAColor(hex: 0x6E8BFF), end: RGBAColor(hex: 0xC86DD7)),
        GradientPreset(name: "Peach", start: RGBAColor(hex: 0xFF9A8B), end: RGBAColor(hex: 0xFF6A88)),
        GradientPreset(name: "Sunrise", start: RGBAColor(hex: 0xF6D365), end: RGBAColor(hex: 0xFDA085)),
        GradientPreset(name: "Mint", start: RGBAColor(hex: 0x43E97B), end: RGBAColor(hex: 0x38F9D7)),
        GradientPreset(name: "Ocean", start: RGBAColor(hex: 0x2E3192), end: RGBAColor(hex: 0x1BFFFF)),
        GradientPreset(name: "Graphite", start: RGBAColor(hex: 0x434343), end: RGBAColor(hex: 0x0F0F0F)),
        GradientPreset(name: "Sunset", top: [0xFDA046, 0xF57C73, 0xB07985, 0x5F71AB, 0x321805]),
        GradientPreset(name: "Dusk peach", top: [0x2B313D, 0x7D8BA7, 0xB2BFD2, 0xFFAF77, 0xFFE4B9]),
        GradientPreset(name: "Night lilac", top: [0x020201, 0x7588AF, 0xB498A7]),
        GradientPreset(name: "Golden hour", top: [0x484843, 0x5E78A4, 0xB5A38F, 0xFAC983, 0xFEEC76]),
        GradientPreset(name: "Blue hour", top: [0x14202C, 0x2B3422, 0x515D6D, 0x768EBF, 0xC8D7F1]),
        GradientPreset(name: "Olive", top: [0x1D1F1B, 0x4A4832, 0x74745D, 0xA7AB57, 0xE8ECF4]),
        GradientPreset(name: "Meadow", top: [0x3F4E36, 0x617F3D, 0xD19B4A, 0xCEDBBC, 0xEDDC23]),
    ]
}
