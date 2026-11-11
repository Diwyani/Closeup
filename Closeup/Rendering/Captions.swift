import AppKit
import AVFoundation
import CoreImage
import CoreText
import Speech

/// One caption line on screen, in recording time.
struct Caption: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    /// When each recognised word was said (recording time). Used to find
    /// filler sounds: voice with no word in it.
    var words: [CaptionWord]?
}

struct CaptionWord: Codable, Equatable, Sendable {
    var text: String?
    var start: Double
    var end: Double
}

enum CaptionError: LocalizedError {
    case notAllowed, unavailable

    var errorDescription: String? {
        switch self {
        case .notAllowed: "Allow Speech Recognition for Closeup in System Settings → Privacy & Security."
        case .unavailable: "Speech recognition isn't available for your language right now."
        }
    }
}

/// Turns the microphone recording into captions with Apple's speech
/// recognition, on this Mac (nothing leaves your computer).
///
/// On macOS 26 it uses SpeechAnalyzer, which works even with Siri and
/// Dictation turned off. Older systems fall back to SFSpeechRecognizer.
enum CaptionGenerator {
    /// One recognised word, in seconds from the start of the file.
    struct Word {
        var text: String
        var start: Double
        var end: Double
    }

    static let maxWords = 7
    static let maxLength = 3.0  // seconds per caption
    static let pause = 0.6      // a gap this long starts a new caption

    /// `offset` is where the mic file starts on the recording's timeline.
    static func generate(from file: URL, offset: Double) async throws -> [Caption] {
        let words: [Word]
        if #available(macOS 26.0, *) {
            words = try await analyze(file)
        } else {
            words = try await recognize(file)
        }
        return group(words, offset: offset)
    }

    @available(macOS 26.0, *)
    private static func analyze(_ file: URL) async throws -> [Word] {
        let current = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        let english = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        guard let locale = current ?? english else { throw CaptionError.unavailable }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        // The language model downloads once, the first time.
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Collect results while the analyzer works through the file.
        let collector = Task { () throws -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    if let range = run.audioTimeRange {
                        words.append(Word(text: text, start: range.start.seconds, end: range.end.seconds))
                    } else if !words.isEmpty {
                        words[words.count - 1].text += text  // punctuation without its own timing
                    }
                }
            }
            return words
        }
        let audio = try AVAudioFile(forReading: file)
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    /// The older API. Needs Siri or Dictation turned on.
    private static func recognize(_ file: URL) async throws -> [Word] {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw CaptionError.notAllowed }
        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable
        else { throw CaptionError.unavailable }

        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.segments)
                } else if let error {
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
        }
        return segments.map { Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
    }

    /// Words → short caption lines, breaking at pauses, sentence ends and length.
    private static func group(_ words: [Word], offset: Double) -> [Caption] {
        var captions: [Caption] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            captions.append(Caption(
                start: first.start + offset,
                end: last.end + offset + 0.2,
                text: current.map(\.text).joined(separator: " "),
                words: current.map { CaptionWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }))
            current = []
        }

        for word in words {
            if let first = current.first, let last = current.last {
                let gap = word.start - last.end
                let length = word.end - first.start
                if gap > pause || length > maxLength || current.count >= maxWords { flush() }
            }
            current.append(word)
            if let end = word.text.last, ".?!".contains(end) { flush() }
        }
        flush()

        // Don't let a caption's tail overlap the next one.
        for index in captions.indices.dropLast() {
            captions[index].end = min(captions[index].end, captions[index + 1].start)
        }
        return captions
    }
}

/// Draws caption and title text as white letters on clear, in the system
/// font, with room around them for a box. Colour, box and shadow are added
/// per frame by FrameCompositor. Cached, since the same text is drawn for
/// many frames in a row.
enum CaptionRenderer {
    private static let cache = NSCache<NSString, CIImage>()

    /// `fontSize` in canvas pixels.
    static func image(for text: String, fontSize: CGFloat, maxWidth: CGFloat, weight: NSFont.Weight = .semibold) -> CIImage? {
        let key = "\(text)|\(Int(fontSize))|\(Int(maxWidth))|\(weight.rawValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let font = NSFont.systemFont(ofSize: fontSize, weight: weight) as CTFont
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)

        let padX = fontSize * 0.6, padY = fontSize * 0.35
        let width = Int(ceil(textSize.width + padX * 2)), height = Int(ceil(textSize.height + padY * 2))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let textRect = CGRect(x: padX, y: padY, width: ceil(textSize.width), height: ceil(textSize.height))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, context)

        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }
}

extension TextLook.Weight {
    var font: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}
