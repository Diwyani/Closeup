import CoreImage
import CoreImage.CIFilterBuiltins

/// Turns one raw frame into one finished frame:
///
///     background → shadow → screen (zoom crop, scaled, rounded) → cursor → camera → captions
///
/// A pure function of (raw frame, time, style), so the live preview and the
/// export are guaranteed to look the same.
///
/// Core Image works with y going UP from the bottom-left, while the cursor
/// log and the camera go y DOWN from the top-left. The flips happen where
/// raw-pixel positions turn into canvas positions.
struct FrameCompositor: Sendable {
    /// Style sizes are in pixels on a canvas whose short side is this long
    /// (1080p), so they look the same at 4K or in a vertical video.
    static let referenceSide = 1080.0

    var style: ExportStyle
    var cursor: CursorTrack?
    /// nil = no zoom; the whole screen is always visible.
    var camera: CameraTrack?
    var sprites = CursorSprites.arrowOnly
    /// Raw video pixels per screen point (2 on Retina).
    var sourceScale: Double
    /// Cuts and speed-ups: turns the edited video's time back into recording
    /// time, which the cursor and camera tracks use.
    var timeMap: TimeMap?
    /// The recording's folder, where a background picture lives.
    var assetFolder: URL?

    /// `camera` is the webcam frame for this moment, if there is one.
    /// `outputTime` is time in the (possibly edited) video.
    func render(source: CIImage, camera: CIImage? = nil, at outputTime: Double, canvas: CGSize) -> CIImage {
        let time = timeMap?.source(at: outputTime) ?? outputTime
        let bounds = CGRect(origin: .zero, size: canvas)
        let unit = min(canvas.width, canvas.height) / Self.referenceSide
        let padding = style.padding * unit

        // Where the screen and camera go, blending between layouts.
        let padded = bounds.insetBy(dx: padding, dy: padding)
        var layout = LayoutGeometry.make(.bubble, bounds: bounds, padded: padded, style: style, unit: unit)
        if let (target, amount) = LayoutGeometry.active(in: style.cameraLayouts, at: time) {
            layout = layout.blended(
                to: LayoutGeometry.make(target, bounds: bounds, padded: padded, style: style, unit: unit), amount)
        }

        // Fit the screen inside its area, centred.
        let sourceSize = source.extent.size
        let available = layout.screenArea
        let fitScale = max(0.01, min(available.width / sourceSize.width, available.height / sourceSize.height))
        let contentSize = CGSize(width: sourceSize.width * fitScale, height: sourceSize.height * fitScale)
        let contentRect = CGRect(
            x: available.midX - contentSize.width / 2, y: available.midY - contentSize.height / 2,
            width: contentSize.width, height: contentSize.height)
        let radius = min(style.cornerRadius * unit, contentRect.width / 2, contentRect.height / 2)

        // The camera picks which part of the screen fills the frame.
        let view = visibleRect(at: time, sourceSize: sourceSize)
        let pixelToCanvas = fitScale * sourceSize.width / view.width
        let viewBottom = sourceSize.height - view.maxY  // same rect, measured from the bottom

        var content = Self.scaled(source.transformed(by: CGAffineTransform(
            translationX: -source.extent.minX - view.minX, y: -source.extent.minY - viewBottom)), by: pixelToCanvas)
            .transformed(by: CGAffineTransform(translationX: contentRect.minX, y: contentRect.minY))
            .cropped(to: contentRect)
        if radius > 0 {
            content = content.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: contentRect),
                kCIInputMaskImageKey: Self.roundedRect(contentRect, radius: radius, color: .white),
            ])
        }

        var image = background(in: bounds)
        if style.shadow > 0 {
            image = shadow(under: contentRect, radius: radius, unit: unit)
                .cropped(to: bounds)
                .composited(over: image)
        }
        image = content.composited(over: image)
        if style.showsCursor, let cursorImage = cursorLayer(
            at: time, sourceSize: sourceSize, view: view, contentRect: contentRect, pixelToCanvas: pixelToCanvas) {
            image = cursorImage.composited(over: image)
        }
        if let camera, layout.cameraOpacity > 0.01 {
            image = cameraLayer(camera, layout: layout, bounds: bounds, unit: unit).composited(over: image)
        }
        for overlay in style.textOverlays {
            let opacity = overlay.opacity(at: time)
            guard opacity > 0, !overlay.text.isEmpty else { continue }
            let fontSize = 72 * unit * overlay.size
            guard let mask = CaptionRenderer.image(
                for: overlay.text, fontSize: fontSize, maxWidth: bounds.width * 0.85, weight: overlay.look.weight.font)
            else { continue }

            var position = overlay.position
            if overlay.avoidsAction, position != .center {
                let busy = actionBands(from: overlay.start, to: overlay.end, sourceSize: sourceSize)
                if position == .top, busy.top, !busy.bottom { position = .bottom }
                else if position == .bottom, busy.bottom, !busy.top { position = .top }
            }
            let height = mask.extent.height
            let y: CGFloat = switch position {
            case .top: bounds.height * 0.92 - height
            case .center: bounds.midY - height / 2
            case .bottom: bounds.height * 0.18
            }
            if overlay.dimsBehind {
                image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45 * opacity)).cropped(to: bounds)
                    .composited(over: image)
            }
            image = drawText(
                mask, at: CGPoint(x: bounds.midX - mask.extent.width / 2, y: y),
                look: overlay.look, fontSize: fontSize, opacity: opacity, over: image)
        }
        if style.showsCaptions, let caption = style.captions?.first(where: { time >= $0.start && time < $0.end }) {
            let fontSize = 44 * unit * style.captionSize
            if let mask = CaptionRenderer.image(
                for: caption.text, fontSize: fontSize, maxWidth: bounds.width * 0.8, weight: style.captionLook.weight.font) {
                var y = bounds.height * 0.07
                if style.captionsAvoidAction {
                    let busy = actionBands(from: caption.start, to: caption.end, sourceSize: sourceSize)
                    if busy.bottom, !busy.top { y = bounds.height * 0.93 - mask.extent.height }
                }
                image = drawText(
                    mask, at: CGPoint(x: bounds.midX - mask.extent.width / 2, y: y),
                    look: style.captionLook, fontSize: fontSize, opacity: 1, over: image)
            }
        }
        return image.cropped(to: bounds)
    }

    // MARK: Text

    /// Draws white text `mask` at `origin` with its box, in a colour that
    /// reads well on what's behind it.
    private func drawText(
        _ mask: CIImage, at origin: CGPoint, look: TextLook, fontSize: CGFloat, opacity: CGFloat, over image: CIImage
    ) -> CIImage {
        let mask = mask.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        let rect = mask.extent
        let radius = fontSize * 0.45

        // The box, and what the text ends up sitting on (to judge contrast).
        var box: CIImage?
        switch look.box {
        case .none:
            break
        case .glass:
            let frosted = image.clampedToExtent().applyingGaussianBlur(sigma: fontSize * 0.5).cropped(to: rect)
            box = Self.solid(look.boxColor, alpha: look.boxOpacity, in: rect).composited(over: frosted)
        case .dark:
            box = Self.solid(RGBAColor(hex: 0x000000), alpha: look.boxOpacity, in: rect)
        case .light:
            box = Self.solid(RGBAColor(hex: 0xFFFFFF), alpha: look.boxOpacity, in: rect)
        case .custom:
            box = Self.solid(look.boxColor, alpha: look.boxOpacity, in: rect)
        }
        box = box.map { Self.rounded($0, rect: rect, radius: radius) }
        let behind = (box ?? CIImage.empty()).composited(over: image.cropped(to: rect))

        // Text colour: chosen on the GPU from the average brightness behind it.
        let fill = look.autoColor ? Self.contrastColor(on: behind) : CIImage(color: look.textColor.ciColor)
        var text = Self.paint(fill, through: mask)
        if look.box == .none {
            // A soft shadow in the opposite colour, so plain text reads on anything.
            let shadowColor = fill.applyingFilter("CIColorInvert")
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.6)])
            let shadow = Self.paint(shadowColor, through: mask)
                .applyingGaussianBlur(sigma: fontSize * 0.12)
                .transformed(by: CGAffineTransform(translationX: 0, y: -fontSize * 0.04))
            text = text.composited(over: shadow)
        }

        var layer = text
        if let box { layer = text.composited(over: box) }
        if opacity < 1 {
            layer = layer.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
        }
        return layer.composited(over: image)
    }

    /// White on dark backgrounds, black on light ones, worked out per frame
    /// on the GPU (no waiting for the CPU).
    private static func contrastColor(on behind: CIImage) -> CIImage {
        let average = behind.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: behind.extent),
        ])
        // Brightness (linear light), turned into 1 for dark (white text) or
        // 0 for light (black text), with a quick blend around the middle.
        let k: CGFloat = 20, threshold: CGFloat = 0.3
        let row = CIVector(x: -k * 0.2126, y: -k * 0.7152, z: -k * 0.0722, w: 0)
        return average
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": row, "inputGVector": row, "inputBVector": row,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: k * threshold, y: k * threshold, z: k * threshold, w: 1),
            ])
            .applyingFilter("CIColorClamp")
            .clampedToExtent()
    }

    /// `color` (any image) shown only where `mask` has letters.
    private static func paint(_ color: CIImage, through mask: CIImage) -> CIImage {
        color.clampedToExtent().cropped(to: mask.extent).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: mask.extent),
            kCIInputMaskImageKey: mask,
        ])
    }

    private static func solid(_ color: RGBAColor, alpha: Double, in rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b, alpha: alpha)).cropped(to: rect)
    }

    private static func rounded(_ image: CIImage, rect: CGRect, radius: CGFloat) -> CIImage {
        image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
            kCIInputMaskImageKey: roundedRect(rect, radius: radius, color: .white),
        ])
    }

    /// Whether the cursor works near the top or bottom of the visible view
    /// at any point in this stretch (checked every quarter second). Decided
    /// once per title, so it never jumps while showing.
    private func actionBands(from start: Double, to end: Double, sourceSize: CGSize) -> (top: Bool, bottom: Bool) {
        guard let cursor else { return (false, false) }
        var top = false, bottom = false
        for t in stride(from: start, through: end, by: 0.25) {
            let point = cursor.position(at: t)
            let view = visibleRect(at: t, sourceSize: sourceSize)
            let y = (point.y * sourceScale - view.minY) / view.height
            let x = (point.x * sourceScale - view.minX) / view.width
            guard (0...1).contains(x), (0...1).contains(y) else { continue }
            if y < 0.3 { top = true }
            if y > 0.7 { bottom = true }
        }
        return (top, bottom)
    }

    // MARK: Camera picture

    /// The webcam filling `layout.cameraRect` (cropped to fit, like "fill"),
    /// with rounded corners and a soft shadow. A circle when it's a bubble.
    private func cameraLayer(_ camera: CIImage, layout: LayoutGeometry, bounds: CGRect, unit: CGFloat) -> CIImage {
        let rect = layout.cameraRect
        let extent = camera.extent
        // The largest part of the picture with the same shape as `rect`.
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let cropWidth = rect.width / scale, cropHeight = rect.height / scale
        let crop = CGRect(x: extent.midX - cropWidth / 2, y: extent.midY - cropHeight / 2, width: cropWidth, height: cropHeight)

        var face = camera.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if style.cameraMirrored {
            face = face.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: cropWidth, ty: 0))
        }
        let radius = min(layout.cameraRadius, rect.width / 2, rect.height / 2)
        face = Self.scaled(face, by: scale)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .cropped(to: rect)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
                kCIInputMaskImageKey: Self.roundedRect(rect, radius: radius, color: .white),
            ])

        let shadow = Self.roundedRect(
            rect.offsetBy(dx: 0, dy: -8 * unit), radius: radius,
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            .applyingGaussianBlur(sigma: 14 * unit)
            .cropped(to: bounds)
        var image = face.composited(over: shadow)
        if layout.cameraOpacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: layout.cameraOpacity),
            ])
        }
        return image
    }

    // MARK: Camera

    /// The part of the raw frame that's visible, in raw pixels, top-left origin.
    private func visibleRect(at time: Double, sourceSize: CGSize) -> CGRect {
        guard let camera else { return CGRect(origin: .zero, size: sourceSize) }
        let (zoom, center) = camera.camera(at: time)
        let width = sourceSize.width / max(1, zoom)
        let height = sourceSize.height / max(1, zoom)
        // Keep the view inside the screen, so we never show past its edges.
        let centerX = min(max(center.x * sourceScale, width / 2), sourceSize.width - width / 2)
        let centerY = min(max(center.y * sourceScale, height / 2), sourceSize.height - height / 2)
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    // MARK: Layers

    private func background(in bounds: CGRect) -> CIImage {
        switch style.backgroundKind {
        case .image:
            if let name = style.backgroundImage, let folder = assetFolder, let image = BackgroundImage.image(
                at: folder.appending(path: name), canvas: bounds.size,
                blur: style.backgroundBlur, dim: style.backgroundDim) {
                return image
            }
            return CIImage(color: style.solidColor.ciColor).cropped(to: bounds)
        case .solid:
            return CIImage(color: style.solidColor.ciColor).cropped(to: bounds)
        case .gradient:
            // CSS-style angle → a direction vector (y up), spanning the whole canvas.
            let angle = style.gradientAngle * .pi / 180
            let direction = CGPoint(x: sin(angle), y: cos(angle))
            let halfLength = (abs(direction.x) * bounds.width + abs(direction.y) * bounds.height) / 2
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(
                x: bounds.midX - direction.x * halfLength, y: bounds.midY - direction.y * halfLength)
            gradient.point1 = CGPoint(
                x: bounds.midX + direction.x * halfLength, y: bounds.midY + direction.y * halfLength)
            gradient.color0 = style.gradientStart.ciColor
            gradient.color1 = style.gradientEnd.ciColor
            return (gradient.outputImage ?? CIImage(color: style.gradientStart.ciColor)).cropped(to: bounds)
        }
    }

    private func shadow(under rect: CGRect, radius: CGFloat, unit: CGFloat) -> CIImage {
        let strength = style.shadow
        let blur = (10 + 50 * strength) * unit
        let offset = (4 + 20 * strength) * unit
        let color = CIColor(red: 0, green: 0, blue: 0, alpha: 0.25 + 0.45 * strength)
        return Self.roundedRect(rect.offsetBy(dx: 0, dy: -offset), radius: radius, color: color)
            .applyingGaussianBlur(sigma: blur / 2)
    }

    private func cursorLayer(
        at time: Double, sourceSize: CGSize, view: CGRect, contentRect: CGRect, pixelToCanvas: CGFloat
    ) -> CIImage? {
        guard let cursor else { return nil }
        let point = cursor.position(at: time)

        // Points → raw video pixels (top-left origin).
        let pixelX = point.x * sourceScale
        let pixelY = point.y * sourceScale
        // Off the recorded area (another display, outside the window): hide it.
        guard pixelX >= 0, pixelY >= 0, pixelX <= sourceSize.width, pixelY <= sourceSize.height else {
            return nil
        }

        // Raw pixels → canvas, through the camera. This is where y flips to
        // Core Image's bottom-up.
        let tip = CGPoint(
            x: contentRect.minX + (pixelX - view.minX) * pixelToCanvas,
            y: contentRect.maxY - (pixelY - view.minY) * pixelToCanvas)

        let opacity = style.hidesIdleCursor ? cursor.visibility(at: time) : 1
        guard opacity > 0.01 else { return nil }

        // Zooming in enlarges the cursor too, like the screen under it.
        let pointToCanvas = sourceScale * pixelToCanvas * style.cursorSize
        let sprite = sprites[cursor.shape(at: time)]
        let press = 1 - 0.2 * cursor.clickAmount(at: time)
        let size = pointToCanvas * press / sprite.pixelsPerPoint
        var image = Self.scaled(sprite.image, by: size)
            .transformed(by: CGAffineTransform(
                translationX: tip.x - sprite.hotspot.x * size, y: tip.y - sprite.hotspot.y * size))

        // Motion blur along the direction of travel, stronger the faster it moves.
        if style.motionBlur {
            let previous = cursor.position(at: time - 1.0 / 60)
            let dx = (point.x - previous.x) * sourceScale * pixelToCanvas
            let dy = -(point.y - previous.y) * sourceScale * pixelToCanvas  // y up
            let radius = min(hypot(dx, dy) * 0.5, 24)
            if radius > 1 {
                image = image.clampedToExtent()
                    .applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: radius,
                        kCIInputAngleKey: atan2(dy, dx),
                    ])
                    .cropped(to: image.extent.insetBy(dx: -radius * 2, dy: -radius * 2))
            }
        }

        // A soft glow that blooms out from each click.
        if style.clickEffect, let elapsed = cursor.timeSinceClick(at: time), elapsed < 0.45 {
            let progress = elapsed / 0.45
            let glowRadius = (8 + 22 * progress) * pointToCanvas
            let glow = CIFilter.radialGradient()
            glow.center = tip
            glow.radius0 = 0
            glow.radius1 = Float(glowRadius)
            glow.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.55 * (1 - progress))
            glow.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            if let glowImage = glow.outputImage?.cropped(to: CGRect(
                x: tip.x - glowRadius, y: tip.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)) {
                image = image.composited(over: glowImage)
            }
        }

        if opacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
        }
        return image.cropped(to: contentRect)  // when zoomed, it can sit past the visible edge
    }

    // MARK: Helpers

    /// Shrinking with Lanczos keeps text crisp (a plain transform would alias
    /// when a 5K screen becomes 1080p). Enlarging uses a normal transform.
    private static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        guard scale < 1 else {
            return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1,
        ])
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(radius)
        generator.color = color
        return generator.outputImage ?? CIImage(color: color).cropped(to: rect)
    }
}
