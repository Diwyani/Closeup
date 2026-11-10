import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// A picture behind the video: imported once into the recording's folder,
/// then filled to the canvas, blurred and dimmed.
///
/// Blurring a large photo on every frame would be slow, so each finished
/// background (per size and setting) is drawn once and reused.
enum BackgroundImage {
    private static let cache = NSCache<NSString, CIImage>()
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// `blur` and `dim` are 0…1.
    static func image(at url: URL, canvas: CGSize, blur: Double, dim: Double) -> CIImage? {
        let key = "\(url.path)|\(Int(canvas.width))x\(Int(canvas.height))|\(blur)|\(dim)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }

        // Fill the canvas, centred, cropping whatever doesn't fit.
        let bounds = CGRect(origin: .zero, size: canvas)
        let extent = source.extent
        let scale = max(canvas.width / extent.width, canvas.height / extent.height)
        var image = source
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(
            translationX: (canvas.width - image.extent.width) / 2, y: (canvas.height - image.extent.height) / 2))

        if blur > 0 {
            // Up to 5% of the short side: soft enough to hide any detail.
            let sigma = blur * min(canvas.width, canvas.height) * 0.05
            image = image.clampedToExtent().applyingGaussianBlur(sigma: sigma)
        }
        image = image.cropped(to: bounds)
        if dim > 0 {
            image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: dim * 0.7)).cropped(to: bounds)
                .composited(over: image)
        }

        guard let rendered = context.createCGImage(image, from: bounds) else { return nil }
        let finished = CIImage(cgImage: rendered)
        cache.setObject(finished, forKey: key)
        return finished
    }

    /// Copies a picture into `folder` (at most 4K on its long side, as JPEG)
    /// and returns the new file's name. Each import gets a new name, so
    /// nothing old is shown from the cache.
    static func importImage(from url: URL, into folder: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 3840,
              ] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }

        let name = "background-\(UUID().uuidString.prefix(8)).jpg"
        let output = folder.appending(path: name)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return name
    }
}
