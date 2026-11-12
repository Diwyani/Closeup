import CoreGraphics
import Foundation

/// How the screen and the webcam share the frame.
enum CameraLayout: String, Codable, CaseIterable, Sendable {
    case bubble, camera, sideBySide, screen

    var title: String {
        switch self {
        case .bubble: "Bubble"
        case .camera: "Camera only"
        case .sideBySide: "Side by side"
        case .screen: "Screen only"
        }
    }
}

/// A stretch of the recording with its own layout (e.g. full-screen camera
/// for an intro). Outside these, the whole-video layout applies.
struct LayoutSegment: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var layout: CameraLayout
}

/// Where the screen and camera sit on the canvas for one layout. Two of
/// these blend smoothly during a layout change.
struct LayoutGeometry {
    /// The screen is fitted (not stretched) inside this area.
    var screenArea: CGRect
    var cameraRect: CGRect
    var cameraRadius: CGFloat
    var cameraOpacity: CGFloat
    /// 1 = the camera panel takes the screen's exact height (side by side),
    /// so both panels line up. Blends with the other values.
    var matchesScreen: CGFloat = 0

    /// How long a layout change takes, in seconds.
    static let transition = 0.45

    /// `bounds` and `padded` are in Core Image coordinates (y up).
    static func make(
        _ layout: CameraLayout, bounds: CGRect, padded: CGRect, style: ExportStyle, unit: CGFloat
    ) -> LayoutGeometry {
        let height = min(bounds.width, bounds.height) * style.cameraSize
        let width = height * style.cameraShape.ratio
        let bubbleRadius = style.cameraShape == .circle ? height / 2 : min(width, height) * style.cameraRoundness
        let margin = 40 * unit
        let isLeft = style.cameraCorner == .topLeft || style.cameraCorner == .bottomLeft
        let isTop = style.cameraCorner == .topLeft || style.cameraCorner == .topRight
        let bubble = CGRect(
            x: isLeft ? margin : bounds.width - margin - width,
            y: isTop ? bounds.height - margin - height : margin,
            width: width, height: height)
        let radius = style.cameraPanelRadius * unit

        switch layout {
        case .bubble:
            return LayoutGeometry(
                screenArea: padded, cameraRect: bubble, cameraRadius: bubbleRadius,
                cameraOpacity: style.showsCamera ? 1 : 0)
        case .screen:
            return LayoutGeometry(screenArea: padded, cameraRect: bubble, cameraRadius: bubbleRadius, cameraOpacity: 0)
        case .camera:
            return LayoutGeometry(screenArea: padded, cameraRect: padded, cameraRadius: radius, cameraOpacity: 1)
        case .sideBySide:
            // A full-height camera panel beside the screen, on the side you
            // choose. Wide videos split left/right, tall ones top/bottom
            // (left = camera on top).
            let gap = 24 * unit
            let share = min(max(style.cameraPanelShare, 0.2), 0.7)
            let cameraFirst = style.cameraSide == .left
            if bounds.width >= bounds.height {
                let cameraWidth = (padded.width - gap) * share
                let screenWidth = padded.width - gap - cameraWidth
                let cameraX = cameraFirst ? padded.minX : padded.maxX - cameraWidth
                let screenX = cameraFirst ? padded.minX + cameraWidth + gap : padded.minX
                return LayoutGeometry(
                    screenArea: CGRect(x: screenX, y: padded.minY, width: screenWidth, height: padded.height),
                    cameraRect: CGRect(x: cameraX, y: padded.minY, width: cameraWidth, height: padded.height),
                    cameraRadius: radius, cameraOpacity: 1, matchesScreen: 1)
            } else {
                let cameraHeight = (padded.height - gap) * share
                let screenHeight = padded.height - gap - cameraHeight
                // Core Image's y goes up, so "top" is the high end.
                let cameraY = cameraFirst ? padded.maxY - cameraHeight : padded.minY
                let screenY = cameraFirst ? padded.minY : padded.maxY - screenHeight
                return LayoutGeometry(
                    screenArea: CGRect(x: padded.minX, y: screenY, width: padded.width, height: screenHeight),
                    cameraRect: CGRect(x: padded.minX, y: cameraY, width: padded.width, height: cameraHeight),
                    cameraRadius: radius, cameraOpacity: 1, matchesScreen: 1)
            }
        }
    }

    func blended(to other: LayoutGeometry, _ amount: CGFloat) -> LayoutGeometry {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * amount }
        func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
        }
        return LayoutGeometry(
            screenArea: mix(screenArea, other.screenArea),
            cameraRect: mix(cameraRect, other.cameraRect),
            cameraRadius: mix(cameraRadius, other.cameraRadius),
            cameraOpacity: mix(cameraOpacity, other.cameraOpacity),
            matchesScreen: mix(matchesScreen, other.matchesScreen))
    }

    /// The layout at `time`: which segment is active and how far it has
    /// eased in (0 = plain bubble, 1 = fully in the segment's layout).
    static func active(in segments: [LayoutSegment], at time: Double) -> (CameraLayout, CGFloat)? {
        guard let segment = segments.first(where: { time >= $0.start - transition && time <= $0.end + transition })
        else { return nil }
        let into = min(time - (segment.start - transition), segment.end + transition - time) / transition
        let t = min(max(into, 0), 1)
        return (segment.layout, t * t * (3 - 2 * t))  // smoothstep
    }
}
