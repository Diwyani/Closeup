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
/// for an intro). Outside these, the camera is a bubble.
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
        let radius = style.cornerRadius * unit

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
            // Screen gets about two thirds; the camera the rest. Wide videos
            // split left/right, tall ones top/bottom.
            let gap = 24 * unit
            if bounds.width >= bounds.height {
                let screenWidth = (padded.width - gap) * 0.64
                return LayoutGeometry(
                    screenArea: CGRect(x: padded.minX, y: padded.minY, width: screenWidth, height: padded.height),
                    cameraRect: CGRect(
                        x: padded.minX + screenWidth + gap, y: padded.minY,
                        width: padded.width - screenWidth - gap, height: padded.height),
                    cameraRadius: radius, cameraOpacity: 1)
            } else {
                let screenHeight = (padded.height - gap) * 0.5
                return LayoutGeometry(
                    screenArea: CGRect(
                        x: padded.minX, y: padded.maxY - screenHeight, width: padded.width, height: screenHeight),
                    cameraRect: CGRect(
                        x: padded.minX, y: padded.minY, width: padded.width, height: padded.height - screenHeight - gap),
                    cameraRadius: radius, cameraOpacity: 1)
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
            cameraOpacity: mix(cameraOpacity, other.cameraOpacity))
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
