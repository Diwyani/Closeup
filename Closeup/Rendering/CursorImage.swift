import CoreGraphics
import CoreImage
import Foundation

/// One cursor look, ready to draw.
struct CursorSprite {
    let image: CIImage
    /// The click point in image pixels (Core Image coordinates, y up).
    let hotspot: CGPoint
    let pixelsPerPoint: CGFloat
}

/// All cursor looks of one recording: our arrow plus the shapes captured
/// while recording (I-beam, hand, app tools).
struct CursorSprites: @unchecked Sendable {  // CIImages are immutable, so sharing is safe
    private var sprites: [Int: CursorSprite] = [:]

    static let arrowOnly = CursorSprites()

    /// Unknown ids (and 0) fall back to our arrow.
    subscript(id: Int) -> CursorSprite {
        sprites[id] ?? CursorImage.arrowSprite
    }

    static func load(_ shapes: [CursorShape], from folder: URL) -> CursorSprites {
        var result = CursorSprites()
        for shape in shapes {
            guard let image = CIImage(contentsOf: folder.appending(path: shape.file)), shape.width > 0 else { continue }
            let pixelsPerPoint = image.extent.width / shape.width
            result.sprites[shape.id] = CursorSprite(
                image: image,
                hotspot: CGPoint(
                    x: shape.hotspotX * pixelsPerPoint,
                    y: image.extent.height - shape.hotspotY * pixelsPerPoint),
                pixelsPerPoint: pixelsPerPoint)
        }
        return result
    }
}

/// Our own clean arrow cursor, drawn once at high resolution and then
/// scaled per frame.
enum CursorImage {
    /// Image pixels per screen point. 4× keeps it crisp even when enlarged.
    static let pixelsPerPoint: CGFloat = 4

    static let arrow: CIImage = rendered.image
    /// The arrow's tip in image pixels (Core Image coordinates, y up).
    static let hotspot: CGPoint = rendered.hotspot

    static let arrowSprite = CursorSprite(image: arrow, hotspot: hotspot, pixelsPerPoint: pixelsPerPoint)

    private static let rendered = draw()

    private static func draw() -> (image: CIImage, hotspot: CGPoint) {
        // The arrow in points, y going down, tip at (0, 0). About 19 pt tall,
        // the same as the macOS cursor.
        let shape = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.2, y: 13.2),
            CGPoint(x: 7, y: 19.2), CGPoint(x: 9.6, y: 18), CGPoint(x: 6.9, y: 12.2),
            CGPoint(x: 12.4, y: 12.2),
        ]
        let margin: CGFloat = 4  // room for the outline and shadow
        let scale = pixelsPerPoint
        let width = Int((12.4 + margin * 2) * scale)
        let height = Int((19.2 + margin * 2) * scale)

        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        // Flip so we can draw with y going down, like the shape above.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: margin, y: margin)

        let path = CGMutablePath()
        path.addLines(between: shape)
        path.closeSubpath()

        // White outline with a soft shadow underneath…
        context.setShadow(
            offset: CGSize(width: 0, height: -0.8 * scale), blur: 2.5 * scale,
            color: CGColor(gray: 0, alpha: 0.35))
        context.setLineJoin(.round)
        context.setLineWidth(1.6)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(path)
        context.drawPath(using: .fillStroke)

        // …then the black arrow on top.
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(path)
        context.fillPath()

        let hotspot = CGPoint(x: margin * scale, y: CGFloat(height) - margin * scale)
        return (CIImage(cgImage: context.makeImage()!), hotspot)
    }
}
