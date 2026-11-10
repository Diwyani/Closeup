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
            guard opacity > 0, !overlay.text.isEmpty, var text = CaptionRenderer.image(
                for: overlay.text, fontSize: 72 * unit * overlay.size, maxWidth: bounds.width * 0.85,
                weight: .bold, background: overlay.hasBackground)
            else { continue }
            let height = text.extent.height
            let y: CGFloat = switch overlay.position {
            case .top: bounds.height * 0.92 - height
            case .center: bounds.midY - height / 2
            case .bottom: bounds.height * 0.18
            }
            text = text.transformed(by: CGAffineTransform(translationX: bounds.midX - text.extent.width / 2, y: y))
            if opacity < 1 {
                text = text.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
                ])
            }
            image = text.composited(over: image)
        }
        if style.showsCaptions, let caption = style.captions?.first(where: { time >= $0.start && time < $0.end }),
           let text = CaptionRenderer.image(
               for: caption.text, fontSize: 44 * unit * style.captionSize, maxWidth: bounds.width * 0.8) {
            let x = bounds.midX - text.extent.width / 2
            let y = bounds.height * 0.07
            image = text.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: image)
        }
        return image.cropped(to: bounds)
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
