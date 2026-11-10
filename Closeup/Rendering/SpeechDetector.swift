import AVFoundation

/// Finds when you're talking, from the microphone recording's loudness.
///
/// Measures 30 ms slices, works out how loud the room is when you're quiet
/// (the noise floor), and counts anything clearly louder as speech. Short
/// gaps between words are bridged, so one sentence is one stretch.
enum SpeechDetector {
    static let window = 0.03
    static let bridge = 0.35   // gaps shorter than this are still speech
    static let minimum = 0.15  // blips shorter than this are noise
    static let padding = 0.15  // breathing room around each stretch

    /// Stretches of speech, in recording time (`offset` = where the file starts).
    static func speech(in file: URL, offset: Double) async -> [ClosedRange<Double>] {
        await Task.detached(priority: .utility) {
            (try? detect(file, offset: offset)) ?? []
        }.value
    }

    private static func detect(_ url: URL, offset: Double) throws -> [ClosedRange<Double>] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate * window)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!

        // Loudness of each slice, in dB.
        var levels: [Double] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: frames)
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            var power = 0.0
            for i in 0..<Int(buffer.frameLength) { power += Double(data[0][i] * data[0][i]) }
            levels.append(10 * log10(max(power / Double(buffer.frameLength), 1e-10)))
        }
        guard !levels.isEmpty else { return [] }

        // The quietest tenth is the room; speech is at least 12 dB above it.
        let floor = levels.sorted()[levels.count / 10]
        let threshold = max(floor + 12, -50)

        var ranges: [ClosedRange<Double>] = []
        var start: Double?
        for (index, level) in levels.enumerated() {
            let time = Double(index) * window
            if level > threshold {
                if start == nil { start = time }
            } else if let begin = start {
                ranges.append(begin...time)
                start = nil
            }
        }
        if let begin = start { ranges.append(begin...Double(levels.count) * window) }

        // Bridge short gaps, drop blips, add padding, move to recording time.
        var merged: [ClosedRange<Double>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound - last.upperBound < bridge {
                merged[merged.count - 1] = last.lowerBound...range.upperBound
            } else {
                merged.append(range)
            }
        }
        // A stretch can land entirely before the video starts (the mic starts
        // first), so drop those rather than make a backwards range.
        return merged
            .filter { $0.upperBound - $0.lowerBound >= minimum }
            .compactMap { range in
                let start = max(0, range.lowerBound - padding + offset)
                let end = range.upperBound + padding + offset
                return end > start ? start...end : nil
            }
    }
}
