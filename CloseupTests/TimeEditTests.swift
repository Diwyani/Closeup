import XCTest

/// Cuts and speed-ups: converting between recording time and video time,
/// and planning the automatic edits.
final class TimeEditTests: XCTestCase {
    // MARK: TimeMap

    func testNoEditsLeavesTimeAlone() {
        let map = TimeMap(edits: [], duration: 10)
        XCTAssertEqual(map.outputDuration, 10, accuracy: 1e-9)
        XCTAssertEqual(map.source(at: 4), 4, accuracy: 1e-9)
        XCTAssertEqual(map.output(at: 4), 4, accuracy: 1e-9)
    }

    func testACutRemovesItsTime() {
        let map = TimeMap(edits: [TimeEdit(kind: .cut, start: 2, end: 5)], duration: 10)
        XCTAssertEqual(map.outputDuration, 7, accuracy: 1e-9)
        XCTAssertEqual(map.output(at: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(map.output(at: 3), 2, accuracy: 1e-9, "inside a cut = where the cut ends")
        XCTAssertEqual(map.output(at: 6), 3, accuracy: 1e-9)
        XCTAssertEqual(map.source(at: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(map.source(at: 3), 6, accuracy: 1e-9)
    }

    func testASpeedUpShrinksItsTime() {
        let map = TimeMap(edits: [TimeEdit(kind: .speed, start: 2, end: 6, speed: 4)], duration: 10)
        XCTAssertEqual(map.outputDuration, 7, accuracy: 1e-9)  // 4 s played in 1 s
        XCTAssertEqual(map.output(at: 4), 2.5, accuracy: 1e-9)
        XCTAssertEqual(map.source(at: 2.5), 4, accuracy: 1e-9)
        XCTAssertEqual(map.source(at: 4), 7, accuracy: 1e-9)
    }

    func testThereAndBackAgainOutsideCuts() {
        let map = TimeMap(edits: [
            TimeEdit(kind: .cut, start: 1, end: 2),
            TimeEdit(kind: .speed, start: 4, end: 8, speed: 2),
            TimeEdit(kind: .cut, start: 9, end: 9.5),
        ], duration: 12)
        for source in [0.0, 0.5, 2.5, 3.9, 5, 7.5, 8.5, 10, 11.9] {
            XCTAssertEqual(map.source(at: map.output(at: source)), source, accuracy: 1e-9, "at \(source)")
        }
        XCTAssertEqual(map.outputDuration, 12 - 1 - 2 - 0.5, accuracy: 1e-9)
    }

    func testEditsAreSortedClampedAndNeverOverlap() {
        let map = TimeMap(edits: [
            TimeEdit(kind: .cut, start: 8, end: 20),      // runs past the end
            TimeEdit(kind: .cut, start: 1, end: 4),
            TimeEdit(kind: .speed, start: 3, end: 6),     // overlaps the first cut
            TimeEdit(kind: .cut, start: 7, end: 7.01),    // too short to matter
        ], duration: 10)
        XCTAssertEqual(map.edits.map(\.start), [1, 4, 8])
        XCTAssertEqual(map.edits.map(\.end), [4, 6, 10])
    }

    func testASpeedBelowOneIsTreatedAsNormalSpeed() {
        let map = TimeMap(edits: [TimeEdit(kind: .speed, start: 2, end: 6, speed: 0.25)], duration: 10)
        XCTAssertEqual(map.outputDuration, 10, accuracy: 1e-9)
    }

    func testTimesOutsideTheVideoAreSafe() {
        let map = TimeMap(edits: [TimeEdit(kind: .cut, start: 2, end: 5)], duration: 10)
        XCTAssertEqual(map.output(at: 99), 7, accuracy: 1e-9)
        XCTAssertEqual(map.source(at: 99), 10, accuracy: 1e-9)
        XCTAssertEqual(map.source(at: -1), 0, accuracy: 1.0001)
    }

    func testCuttingEverythingLeavesAnEmptyVideo() {
        let map = TimeMap(edits: [TimeEdit(kind: .cut, start: 0, end: 10)], duration: 10)
        XCTAssertEqual(map.outputDuration, 0)
        XCTAssertEqual(map.output(at: 5), 0)
    }

    // MARK: Automatic edits

    private func log(moves times: [Double]) -> CursorLog {
        // Each move lands somewhere new, so it counts as real activity.
        CursorLog(scale: 2, width: 1000, height: 600, events: times.enumerated().map {
            CursorEvent(t: $1, x: Double($0) * 50, y: 0, type: .move)
        })
    }

    private func plan(
        _ log: CursorLog, speech: [ClosedRange<Double>] = [], duration: Double = 30,
        speedUp: Bool = true, cutSilence: Bool = true, fillers: [ClosedRange<Double>] = []
    ) -> [TimeEdit] {
        AutoEditPlanner.edits(
            from: log, speech: speech, duration: duration, speedUp: speedUp, speed: 4,
            cutSilence: cutSilence, silenceLength: 1.5, fillers: fillers)
    }

    func testALongQuietGapIsSpedUpWithNormalSpeedAroundIt() {
        let edits = plan(log(moves: [0, 1, 11, 30]), duration: 30, cutSilence: false)
        XCTAssertEqual(edits.first?.kind, .speed)
        XCTAssertEqual(edits.first!.start, 1 + AutoEditPlanner.speedMargin, accuracy: 1e-9)
        XCTAssertEqual(edits.first!.end, 11 - AutoEditPlanner.speedMargin, accuracy: 1e-9)
        XCTAssertEqual(edits.first?.speed, 4)
    }

    func testAShortQuietGapIsCutLeavingAPause() {
        let edits = plan(log(moves: [0, 1, 3, 3.5, 4, 4.5, 5]), duration: 5, speedUp: false)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].kind, .cut)
        XCTAssertEqual(edits[0].start, 1 + AutoEditPlanner.cutPause, accuracy: 1e-9)
        XCTAssertEqual(edits[0].end, 3 - AutoEditPlanner.cutPause, accuracy: 1e-9)
    }

    func testSpeechIsNeverCutOrSpedUp() {
        let speech = [2.0...12.0]
        let edits = plan(log(moves: [0, 1, 20]), speech: speech, duration: 20)
        for edit in edits {
            XCTAssertFalse(edit.start < 12 && edit.end > 2, "\(edit.kind) from \(edit.start) to \(edit.end) touches speech")
        }
        XCTAssertFalse(edits.isEmpty)
    }

    func testEverythingOffGivesOnlyFillerCuts() {
        let edits = plan(log(moves: [0, 20]), speedUp: false, cutSilence: false, fillers: [3.0...3.4])
        XCTAssertEqual(edits.map(\.kind), [.cut])
        XCTAssertEqual(edits[0].start, 3)
    }

    func testAFillerInsideAnotherEditIsNotCutTwice() {
        let edits = plan(log(moves: [0, 1, 11, 30]), duration: 30, fillers: [5.0...5.3])
        XCTAssertFalse(edits.contains { $0.kind == .cut && $0.start == 5 })
    }

    func testEditsComeOutInTimeOrder() {
        let edits = plan(log(moves: [0, 1, 11, 13.5, 30]), duration: 30)
        XCTAssertEqual(edits.map(\.start), edits.map(\.start).sorted())
        XCTAssertGreaterThanOrEqual(edits.count, 2)
    }

    // MARK: Auto-trim

    func testAutoTrimKeepsFromJustBeforeTheFirstActionToJustAfterTheLast() {
        let log = CursorLog(scale: 2, width: 1000, height: 600, events: [
            CursorEvent(t: 0, x: 0, y: 0, type: .move),
            CursorEvent(t: 4, x: 0, y: 0, type: .leftDown),
            CursorEvent(t: 12, x: 0, y: 0, type: .typing),
            CursorEvent(t: 19.5, x: 0, y: 0, type: .leftDown),  // reaching for Stop: ignored
        ])
        let trim = AutoEditPlanner.trim(from: log, speech: [], duration: 20)
        XCTAssertEqual(trim.lowerBound, 3.5, accuracy: 1e-9)
        XCTAssertEqual(trim.upperBound, 13, accuracy: 1e-9)
    }

    func testAutoTrimCountsSpeechAndKeepsEverythingWhenNothingHappened() {
        let empty = CursorLog(scale: 2, width: 1000, height: 600, events: [])
        XCTAssertEqual(AutoEditPlanner.trim(from: empty, speech: [], duration: 20), 0...20)
        let spoken = AutoEditPlanner.trim(from: empty, speech: [5.0...9.0], duration: 20)
        XCTAssertEqual(spoken.lowerBound, 4.5, accuracy: 1e-9)
        XCTAssertEqual(spoken.upperBound, 10, accuracy: 1e-9)
    }

    // MARK: Filler sounds

    func testFillerWordsAreRecognised() {
        XCTAssertTrue(FillerDetector.isFiller(CaptionWord(text: "Um,", start: 0, end: 1)))
        XCTAssertTrue(FillerDetector.isFiller(CaptionWord(text: "uh", start: 0, end: 1)))
        XCTAssertFalse(FillerDetector.isFiller(CaptionWord(text: "umbrella", start: 0, end: 1)))
        XCTAssertFalse(FillerDetector.isFiller(CaptionWord(text: nil, start: 0, end: 1)))
    }

    func testAWrittenDownFillerIsCutWithoutTouchingItsNeighbours() {
        let words = [
            CaptionWord(text: "Hello", start: 1, end: 1.5),
            CaptionWord(text: "um", start: 1.52, end: 2.0),
            CaptionWord(text: "world", start: 2.02, end: 2.5),
        ]
        let fillers = FillerDetector.fillers(voiced: [], words: words)
        XCTAssertEqual(fillers.count, 1)
        XCTAssertGreaterThanOrEqual(fillers[0].lowerBound, 1.5)
        XCTAssertLessThanOrEqual(fillers[0].upperBound, 2.02)
    }

    func testUnrecognisedShortVoiceIsAFillerButLongVoiceIsNot() {
        let words = [CaptionWord(text: "Hello", start: 0, end: 0.5), CaptionWord(text: "there", start: 10, end: 10.5)]
        let fillers = FillerDetector.fillers(voiced: [3.0...3.5, 5.0...8.0, 0.1...0.4], words: words)
        XCTAssertEqual(fillers.count, 1)
        XCTAssertEqual(fillers[0].lowerBound, 3 - FillerDetector.margin, accuracy: 1e-9)
    }

    func testNoCaptionsMeansNoFillers() {
        XCTAssertTrue(FillerDetector.fillers(voiced: [3.0...3.5], words: []).isEmpty)
    }
}
