// Makes the tiny sample recording the golden export test uses:
//
//     swift scripts/make-fixture.swift CloseupTests/Fixtures
//
// It draws a fake 320×200 pt "screen" (640×400 pixels, like a Retina display)
// for 2 seconds, and writes a cursor log with a move and one click.
// You only need to run this if you want a different sample; afterwards delete
// CloseupTests/Fixtures/golden-*.png and run the tests twice (see MAINTENANCE.md).
import AVFoundation
import CoreGraphics
import CoreText
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "CloseupTests/Fixtures")
let width = 640, height = 400, fps = 30, frames = 60

func drawFrame(_ index: Int, into buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
        context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        context.fill(rect)
    }
    // y goes up here: the title bar is at the top of the picture.
    fill(0.96, 0.96, 0.97, CGRect(x: 0, y: 0, width: width, height: height))
    fill(0.85, 0.86, 0.88, CGRect(x: 0, y: height - 44, width: width, height: 44))
    fill(1.0, 0.37, 0.34, CGRect(x: 16, y: height - 30, width: 16, height: 16))
    fill(1.0, 0.74, 0.18, CGRect(x: 40, y: height - 30, width: 16, height: 16))
    fill(0.16, 0.78, 0.25, CGRect(x: 64, y: height - 30, width: 16, height: 16))
    // Three cards, so each corner of the screen looks different.
    fill(0.20, 0.45, 0.95, CGRect(x: 40, y: 220, width: 160, height: 100))
    fill(0.95, 0.55, 0.15, CGRect(x: 240, y: 220, width: 160, height: 100))
    fill(0.55, 0.25, 0.85, CGRect(x: 440, y: 220, width: 160, height: 100))
    // A "button" where the click lands (240, 140 in points from the top-left).
    fill(0.10, 0.10, 0.12, CGRect(x: 420, y: 90, width: 120, height: 60))
    // A progress bar that grows, so every frame is different.
    fill(0.80, 0.80, 0.82, CGRect(x: 40, y: 40, width: 560, height: 16))
    fill(0.10, 0.70, 0.55, CGRect(x: 40, y: 40, width: 560 * index / (frames - 1), height: 16))
    let text = NSAttributedString(string: "Closeup fixture", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1),
    ])
    context.textPosition = CGPoint(x: 40, y: 170)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let videoURL = folder.appendingPathComponent("fixture-screen.mov")
try? FileManager.default.removeItem(at: videoURL)
let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000, AVVideoMaxKeyFrameIntervalKey: fps],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
guard writer.startWriting() else { fatalError("\(writer.error!)") }
writer.startSession(atSourceTime: .zero)
for index in 0..<frames {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    drawFrame(index, into: buffer!)
    adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps)))
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("\(writer.error!)") }

// The cursor glides from the blue card to the dark button and clicks it at 1.0 s.
var events: [[String: Any]] = []
for step in 0...24 {
    let t = 0.2 + Double(step) * 0.03
    let f = Double(step) / 24
    events.append(["t": (t * 1000).rounded() / 1000, "x": 60 + (240 - 60) * f, "y": 60 + (140 - 60) * f, "type": "move"])
}
events.append(["t": 1.0, "x": 240, "y": 140, "type": "leftDown"])
events.append(["t": 1.08, "x": 240, "y": 140, "type": "leftUp"])
let cursor: [String: Any] = ["version": 1, "scale": 2, "width": 320, "height": 200, "events": events]
try JSONSerialization.data(withJSONObject: cursor, options: [.sortedKeys])
    .write(to: folder.appendingPathComponent("fixture-cursor.json"))

let project: [String: Any] = [
    "version": 1, "createdAt": "2026-11-01T14:03:22Z",
    "source": ["kind": "display", "name": "Fixture display", "displayID": 1],
    "captureFrame": ["x": 0, "y": 0, "width": 320, "height": 200],
    "scale": 2, "videoWidth": width, "videoHeight": height, "fps": 60,
    "duration": Double(frames) / Double(fps), "frameCount": frames, "droppedFrameCount": 0,
    "displays": [["id": 1, "frame": ["x": 0, "y": 0, "width": 320, "height": 200], "scale": 2, "isPrimary": true]],
]
try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appendingPathComponent("fixture-project.json"))
print("Wrote the fixture to \(folder.path)")
