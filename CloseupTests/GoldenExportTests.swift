import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// The "does the export still look right" test.
///
/// Exports the sample recording with the default look, takes three frames
/// from the finished MP4 and compares each with a reference picture in
/// CloseupTests/Fixtures (golden-*.png). Small differences are allowed,
/// because video compression isn't identical on every Mac.
///
/// If you changed the look ON PURPOSE: delete the golden-*.png files, run the
/// tests once (this test fails and saves new pictures), look at the new
/// pictures, then run again.
@MainActor
final class GoldenExportTests: XCTestCase {
    /// Seconds into the exported video: cursor moving; mid-zoom just after
    /// the click (glow visible); fully zoomed in.
    static let frameTimes = [0.3, 1.15, 1.9]
    /// Average difference per colour value, out of 255.
    static let allowedAverageDifference = 3.0
    /// Share of pixels allowed to be clearly different (more than 40 of 255).
    static let allowedDifferentPixels = 0.02

    func testExportMatchesTheReferenceFrames() async throws {
        let project = try FixtureProject.make()
        defer { project.delete() }
        let model = try await ProjectEditorModel.load(project)
        let url = try await FixtureProject.export(model)

        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await XCTUnwrap(track).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)

        var recorded: [String] = []
        for time in Self.frameTimes {
            let frame = try await Self.frame(of: asset, at: time)
            let name = String(format: "golden-%.2f.png", time)
            let referenceURL = FixtureProject.folder.appending(path: name)
            guard let reference = Self.loadPNG(referenceURL) else {
                try Self.savePNG(frame, to: referenceURL)
                recorded.append(name)
                continue
            }
            let difference = try Self.compare(frame, reference)
            if difference.average > Self.allowedAverageDifference || difference.differentPixels > Self.allowedDifferentPixels {
                let actual = FileManager.default.temporaryDirectory.appending(path: "closeup-actual-\(name)")
                try? Self.savePNG(frame, to: actual)
                XCTFail("""
                    The exported frame at \(time) s no longer matches \(name): average difference \
                    \(String(format: "%.2f", difference.average)) (allowed \(Self.allowedAverageDifference)), \
                    \(String(format: "%.1f%%", difference.differentPixels * 100)) of pixels clearly different \
                    (allowed \(Self.allowedDifferentPixels * 100)%). What the export looks like now: \(actual.path)
                    """)
            }
        }
        if !recorded.isEmpty {
            XCTFail("No reference picture for \(recorded.joined(separator: ", ")), so I saved new ones in CloseupTests/Fixtures. Look at them, then run the tests again.")
        }
    }

    /// The comparison itself has to notice real changes, or the test above proves nothing.
    func testComparisonNoticesAChangedLook() async throws {
        let project = try FixtureProject.make()
        defer { project.delete() }
        var style = ExportStyle()
        style.padding = 160  // a much smaller screen in the frame
        try style.save(to: project.styleURL)
        let model = try await ProjectEditorModel.load(project)
        let asset = AVURLAsset(url: try await FixtureProject.export(model))
        let frame = try await Self.frame(of: asset, at: Self.frameTimes[0])
        let name = String(format: "golden-%.2f.png", Self.frameTimes[0])
        let reference = try XCTUnwrap(Self.loadPNG(FixtureProject.folder.appending(path: name)), "run testExportMatchesTheReferenceFrames first")
        let difference = try Self.compare(frame, reference)
        XCTAssertTrue(
            difference.average > Self.allowedAverageDifference || difference.differentPixels > Self.allowedDifferentPixels,
            "a clearly different export passed the comparison (average \(difference.average), \(difference.differentPixels))")
    }

    // MARK: Pictures

    /// One frame of the video at half size (640×360): plenty to spot a
    /// changed look, and it keeps the reference files small.
    static func frame(of asset: AVAsset, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 640, height: 360)
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    static func loadPNG(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func savePNG(_ image: CGImage, to url: URL) throws {
        // Through plain sRGB pixels first, so the file doesn't depend on the video's colour tags.
        let context = try bitmap(image.width, image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let plain = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, plain, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func bitmap(_ width: Int, _ height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileReadUnknown) }
        return context
    }

    private static func pixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        let context = try bitmap(width, height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    static func compare(_ a: CGImage, _ b: CGImage) throws -> (average: Double, differentPixels: Double) {
        let width = b.width, height = b.height
        let first = try pixels(a, width: width, height: height)
        let second = try pixels(b, width: width, height: height)
        var total = 0, different = 0
        for pixel in 0..<(width * height) {
            var worst = 0
            for channel in 0..<3 {
                let d = abs(Int(first[pixel * 4 + channel]) - Int(second[pixel * 4 + channel]))
                total += d
                worst = max(worst, d)
            }
            if worst > 40 { different += 1 }
        }
        return (Double(total) / Double(width * height * 3), Double(different) / Double(width * height))
    }
}
