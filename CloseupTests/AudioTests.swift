import AVFoundation
import XCTest

/// Speech detection and audio clean-up, on made-up microphone files.
final class AudioTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "closeup-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A "microphone" file: quiet hiss, with a louder tone wherever `loud` says.
    static func makeMicrophoneFile(
        at url: URL, sampleRate: Double, channels: Int, seconds: Double, loud: [ClosedRange<Double>]
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        ]
        if sampleRate >= 44_100 { settings[AVEncoderBitRateKey] = 96_000 * channels }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        var noise = SystemRandomNumberGenerator()
        for channel in 0..<channels {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(count) {
                let t = Double(i) / sampleRate
                let hiss = Float.random(in: -0.001...0.001, using: &noise)
                let isLoud = loud.contains { $0.contains(t) }
                data[i] = hiss + (isLoud ? Float(0.3 * sin(2 * .pi * 220 * t)) : 0)
            }
        }
        try file.write(from: buffer)
    }

    func testSpeechDetectorFindsTheLoudStretches() async throws {
        let url = folder.appending(path: "microphone.m4a")
        try Self.makeMicrophoneFile(at: url, sampleRate: 48_000, channels: 1, seconds: 6, loud: [1.0...2.0, 4.0...5.0])
        let result = await SpeechDetector.speech(in: url, offset: 0)
        XCTAssertEqual(result.speech.count, 2)
        XCTAssertEqual(result.speech[0].lowerBound, 1 - SpeechDetector.padding, accuracy: 0.12)
        XCTAssertEqual(result.speech[0].upperBound, 2 + SpeechDetector.padding, accuracy: 0.12)
        XCTAssertEqual(result.speech[1].lowerBound, 4 - SpeechDetector.padding, accuracy: 0.12)
        XCTAssertEqual(result.voiced.count, 2)
    }

    func testSpeechTimesMoveWithTheMicrophonesOffset() async throws {
        let url = folder.appending(path: "microphone.m4a")
        try Self.makeMicrophoneFile(at: url, sampleRate: 48_000, channels: 1, seconds: 6, loud: [0.2...0.6, 4.0...5.0])
        // The mic started 1.5 s before the screen: the first burst is entirely before the video.
        let result = await SpeechDetector.speech(in: url, offset: -1.5)
        XCTAssertEqual(result.speech.count, 1)
        XCTAssertEqual(result.speech[0].lowerBound, 2.5 - SpeechDetector.padding, accuracy: 0.12)
    }

    func testSpeechDetectorSurvivesAMissingFile() async {
        let result = await SpeechDetector.speech(in: folder.appending(path: "nope.m4a"), offset: 0)
        XCTAssertTrue(result.speech.isEmpty)
    }

    /// Clean-up must work (or fail politely) for every kind of microphone:
    /// built-in (48 kHz), older USB (44.1 kHz stereo) and Bluetooth headsets (24 or 16 kHz).
    func testAudioCleanUpHandlesEveryMicrophoneFormat() async throws {
        for (rate, channels) in [(48_000.0, 1), (44_100.0, 2), (24_000.0, 1), (16_000.0, 1)] {
            let input = folder.appending(path: "mic-\(Int(rate))-\(channels).m4a")
            let output = folder.appending(path: "clean-\(Int(rate))-\(channels).m4a")
            try Self.makeMicrophoneFile(at: input, sampleRate: rate, channels: channels, seconds: 2, loud: [0.5...1.5])
            try await AudioCleaner.clean(input, to: output)
            let cleaned = try AVAudioFile(forReading: output)
            let seconds = Double(cleaned.length) / cleaned.processingFormat.sampleRate
            XCTAssertEqual(seconds, 2, accuracy: 0.15, "\(Int(rate)) Hz, \(channels) ch")
        }
    }
}
