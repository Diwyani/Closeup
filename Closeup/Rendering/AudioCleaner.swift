import AVFoundation
import AudioToolbox

/// Makes a cleaned-up copy of the microphone recording:
///
///     voice isolation (Apple's ML noise removal) → rumble filter → gentle gate & compressor → even loudness
///
/// Done once, offline, into microphone-clean.m4a, so the original stays untouched.
enum AudioCleaner {
    /// Speech level we aim for, in dBFS RMS (roughly -16 LUFS: the loudness
    /// YouTube and podcasts use).
    static let targetLevel = -19.0

    static func clean(_ input: URL, to output: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let processed = output.deletingLastPathComponent().appending(path: "microphone-processing.caf")
            defer { try? FileManager.default.removeItem(at: processed) }
            do {
                try render(input, to: processed, isolatingVoice: true)
            } catch {
                // Voice isolation isn't available everywhere; the rest still helps.
                try render(input, to: processed, isolatingVoice: false)
            }
            try normalize(processed, to: output)
        }.value
    }

    // MARK: Pass 1: effects

    private static func render(_ input: URL, to output: URL, isolatingVoice: Bool) throws {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        var chain: [AVAudioNode] = [player]
        if isolatingVoice {
            // Apple's Sound Isolation audio unit ('vois'), the same tech as
            // Voice Isolation in FaceTime.
            let description = AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: 0x766F_6973,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            var lookup = description
            guard AudioComponentFindNext(nil, &lookup) != nil else { throw CocoaError(.featureUnsupported) }
            chain.append(AVAudioUnitEffect(audioComponentDescription: description))
        }

        // Cut low rumble (desk bumps, fans, air conditioning).
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 80
        eq.bands[0].bypass = false
        chain.append(eq)

        // Quiet the room between words a little, and even out loud/soft words.
        let dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        let unit = dynamics.audioUnit
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -24, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 6, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 2, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, -55, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.005, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.15, 0)
        chain.append(dynamics)

        for node in chain.dropFirst() { engine.attach(node) }
        for (from, to) in zip(chain, chain.dropFirst()) { engine.connect(from, to: to, format: format) }
        engine.connect(chain.last!, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleFile(file, at: nil)
        player.play()
        defer { engine.stop() }

        let out = try AVAudioFile(forWriting: output, settings: format.settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while engine.manualRenderingSampleTime < file.length {
            let frames = AVAudioFrameCount(min(Int64(4096), file.length - engine.manualRenderingSampleTime))
            switch try engine.renderOffline(frames, to: buffer) {
            case .success: try out.write(from: buffer)
            case .error: throw CocoaError(.fileWriteUnknown)
            default: continue
            }
        }
    }

    // MARK: Pass 2: loudness

    /// Measures how loud the speech is (ignoring silence), then turns the
    /// whole file up or down to the target, with a soft limiter for peaks.
    private static func normalize(_ input: URL, to output: URL) throws {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let window = AVAudioFrameCount(format.sampleRate * 0.05)  // 50 ms
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window)!

        // Speech level: average power of the 50 ms windows louder than -45 dB.
        var speechPower = 0.0, speechWindows = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: window)
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            var power = 0.0
            for channel in 0..<channels {
                for i in 0..<Int(buffer.frameLength) { power += Double(data[channel][i] * data[channel][i]) }
            }
            power /= Double(Int(buffer.frameLength) * channels)
            if power > pow(10, -45 / 10) {
                speechPower += power
                speechWindows += 1
            }
        }
        let level = speechWindows > 0 ? 10 * log10(speechPower / Double(speechWindows)) : targetLevel
        let gain = Float(pow(10, min(max(targetLevel - level, -12), 24) / 20))

        file.framePosition = 0
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        // Low sample rates (Bluetooth headsets record at 16 or 24 kHz) can't
        // be encoded at this bitrate; there the encoder picks its own.
        if format.sampleRate >= 44_100 { settings[AVEncoderBitRateKey] = 128_000 * channels }
        let out = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: window)
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            for channel in 0..<channels {
                for i in 0..<Int(buffer.frameLength) { data[channel][i] = limit(data[channel][i] * gain) }
            }
            try out.write(from: buffer)
        }
    }

    /// Leaves normal levels alone and rounds off peaks so they never clip.
    private static func limit(_ x: Float) -> Float {
        let knee: Float = 0.8
        let magnitude = abs(x)
        guard magnitude > knee else { return x }
        let over = magnitude - knee
        return (knee + (1 - knee) * tanh(over / (1 - knee))) * (x < 0 ? -1 : 1)
    }
}
