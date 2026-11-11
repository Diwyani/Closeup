import Foundation

/// A cut (removed) or sped-up stretch of the recording, in recording time.
struct TimeEdit: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case cut, speed
    }

    var id = UUID()
    var kind: Kind
    var start: Double
    var end: Double
    /// For `.speed`: 4 = four times as fast.
    var speed = 4.0
}

/// Plans the automatic edits from what happened while recording:
///
/// - **Busy** = mouse moves, clicks, typing, or you talking.
/// - A quiet gap of 3 s or more is **sped up** (you still see what changed
///   on screen, e.g. something loading), keeping 0.75 s of normal speed
///   around it.
/// - A shorter quiet gap (from `silenceLength` up to 3 s) is **cut**, leaving
///   a short pause so it doesn't feel jumpy. With speed-ups off, every quiet
///   gap that long is cut.
/// - Nothing that has your voice in it is ever sped up or cut.
enum AutoEditPlanner {
    static let longGap = 3.0          // quiet this long → speed up instead of cut
    static let speedMargin = 0.75     // normal speed kept around actions
    static let cutPause = 0.3         // pause left on each side of a cut

    /// `fillers`: filler sounds to cut too (see FillerDetector).
    static func edits(
        from log: CursorLog, speech: [ClosedRange<Double>], duration: Double,
        speedUp: Bool, speed: Double, cutSilence: Bool, silenceLength: Double,
        fillers: [ClosedRange<Double>] = []
    ) -> [TimeEdit] {
        var fillerCuts = fillers.map { TimeEdit(kind: .cut, start: $0.lowerBound, end: $0.upperBound) }
        guard speedUp || cutSilence else { return fillerCuts }
        var busy = activityTimes(log).map { $0...$0 } + speech
        busy.sort { $0.lowerBound < $1.lowerBound }

        var edits: [TimeEdit] = []
        var last = 0.0
        for range in busy + [duration...duration] {
            let gap = range.lowerBound - last
            if speedUp, gap >= longGap {
                let start = last + speedMargin, end = range.lowerBound - speedMargin
                if end - start >= 1 { edits.append(TimeEdit(kind: .speed, start: start, end: end, speed: speed)) }
            } else if cutSilence, gap >= silenceLength {
                let start = last + cutPause, end = range.lowerBound - cutPause
                if end - start >= 0.3 { edits.append(TimeEdit(kind: .cut, start: start, end: end)) }
            }
            last = max(last, range.upperBound)
        }
        fillerCuts.removeAll { cut in edits.contains { $0.start < cut.end && cut.start < $0.end } }
        return (edits + fillerCuts).sorted { $0.start < $1.start }
    }

    /// The part worth keeping: from just before your first click, keystroke
    /// or word to just after your last one. Ignores the last moments, when
    /// you're reaching for Stop.
    static func trim(from log: CursorLog, speech: [ClosedRange<Double>], duration: Double) -> ClosedRange<Double> {
        let ending = duration - 1.5
        var times = log.events.filter { ($0.isClick || $0.type == .typing) && $0.t < ending }.map(\.t)
        for range in speech where range.lowerBound < ending { times += [range.lowerBound, min(range.upperBound, ending)] }
        guard let first = times.min(), let last = times.max() else { return 0...duration }
        let start = max(0, first - 0.5)
        let end = min(duration, last + 1.0)
        return end - start >= 1 ? start...end : 0...duration
    }

    /// Visible mouse moves, clicks and typing.
    private static func activityTimes(_ log: CursorLog) -> [Double] {
        var times: [Double] = []
        var previous: (x: Double, y: Double)?
        for event in log.events {
            switch event.type {
            case .move:
                if previous.map({ hypot(event.x - $0.x, event.y - $0.y) > 1 }) ?? true { times.append(event.t) }
                previous = (event.x, event.y)
            case .typing:
                times.append(event.t)
            default:
                if event.isClick { times.append(event.t) }
            }
        }
        return times
    }
}

/// Finds "um", "uh" and similar sounds, two ways:
/// - words the recogniser wrote down as a filler ("uh", "um", "erm"…),
/// - short bursts of voice it didn't turn into any word (it often skips
///   fillers, coughs and loud breaths).
enum FillerDetector {
    static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "ahh", "hmm", "mm", "eh"]

    static func isFiller(_ word: CaptionWord) -> Bool {
        guard let text = word.text else { return false }
        return fillerWords.contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    static let shortest = 0.2   // shorter bursts are clicks or consonants
    static let longest = 1.2    // longer ones are probably real, unrecognised words
    static let margin = 0.05    // cut a little around the sound

    static func fillers(voiced: [ClosedRange<Double>], words allWords: [CaptionWord]) -> [ClosedRange<Double>] {
        guard !allWords.isEmpty else { return [] }
        let sorted = allWords.sorted { $0.start < $1.start }
        let words = sorted.filter { !isFiller($0) }  // the real words, never cut
        var fillers: [ClosedRange<Double>] = []

        // Fillers the recogniser wrote down.
        for filler in sorted where isFiller(filler) {
            let previousEnd = words.last { $0.end <= filler.start + margin }?.end ?? -.infinity
            let nextStart = words.first { $0.start >= filler.end - margin }?.start ?? .infinity
            let start = max(filler.start - margin, previousEnd + 0.03)
            let end = min(filler.end + margin, nextStart - 0.03)
            if end - start >= 0.1 { fillers.append(start...end) }
        }

        // Voice the recogniser skipped.
        for sound in voiced {
            let length = sound.upperBound - sound.lowerBound
            guard length >= shortest, length <= longest else { continue }
            // Mostly not covered by a recognised word.
            let covered = words.reduce(0.0) {
                $0 + max(0, min($1.end, sound.upperBound) - max($1.start, sound.lowerBound))
            }
            guard covered < length * 0.2 else { continue }
            // Never cut into the words on either side.
            let previousEnd = words.last { $0.end <= sound.lowerBound + margin }?.end ?? -.infinity
            let nextStart = words.first { $0.start >= sound.upperBound - margin }?.start ?? .infinity
            let start = max(sound.lowerBound - margin, previousEnd + 0.03)
            let end = min(sound.upperBound + margin, nextStart - 0.03)
            if end - start >= 0.15, !fillers.contains(where: { $0.overlaps(start...end) }) {
                fillers.append(start...end)
            }
        }
        return fillers.sorted { $0.lowerBound < $1.lowerBound }
    }
}

/// Converts between recording time (what the cursor log, zooms and timeline
/// use) and output time (the edited video, after cuts and speed-ups).
struct TimeMap: Sendable {
    private struct Piece {
        let outputStart: Double
        let sourceStart: Double
        let sourceEnd: Double
        let speed: Double
        var outputEnd: Double { outputStart + (sourceEnd - sourceStart) / speed }
    }

    /// The edits actually applied: sorted, inside the recording, not overlapping.
    let edits: [TimeEdit]
    private let pieces: [Piece]

    init(edits: [TimeEdit], duration: Double) {
        var cleaned: [TimeEdit] = []
        for var edit in edits.sorted(by: { $0.start < $1.start }) {
            edit.start = max(edit.start, cleaned.last?.end ?? 0)
            edit.end = min(edit.end, duration)
            if edit.end - edit.start > 0.05 { cleaned.append(edit) }
        }
        self.edits = cleaned

        var pieces: [Piece] = []
        var source = 0.0
        var output = 0.0
        func keep(until end: Double, speed: Double) {
            guard end > source else { return }
            let piece = Piece(outputStart: output, sourceStart: source, sourceEnd: end, speed: speed)
            pieces.append(piece)
            output = piece.outputEnd
            source = end
        }
        for edit in cleaned {
            keep(until: edit.start, speed: 1)
            if edit.kind == .speed {
                keep(until: edit.end, speed: max(edit.speed, 1))
            } else {
                source = edit.end  // a cut: skip it
            }
        }
        keep(until: duration, speed: 1)
        self.pieces = pieces
    }

    var outputDuration: Double { pieces.last?.outputEnd ?? 0 }

    /// Output time → recording time.
    func source(at output: Double) -> Double {
        guard let piece = pieces.last(where: { $0.outputStart <= output }) ?? pieces.first else { return output }
        return min(piece.sourceEnd, piece.sourceStart + (output - piece.outputStart) * piece.speed)
    }

    /// Recording time → output time. Inside a cut, that's where the cut ends.
    func output(at source: Double) -> Double {
        if let piece = pieces.first(where: { source < $0.sourceEnd }) {
            return piece.outputStart + max(0, source - piece.sourceStart) / piece.speed
        }
        return outputDuration
    }
}
