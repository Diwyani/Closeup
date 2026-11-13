import XCTest

/// Smoothing and lookups for the drawn cursor.
final class CursorTrackTests: XCTestCase {
    private func log(_ events: [CursorEvent]) -> CursorLog {
        CursorLog(scale: 2, width: 1000, height: 600, events: events)
    }

    func testWithoutSmoothingThePositionHoldsTheLastEvent() {
        let track = CursorTrack(log: log([
            CursorEvent(t: 0, x: 100, y: 100, type: .move),
            CursorEvent(t: 1, x: 300, y: 200, type: .move),
        ]), duration: 2, smoothing: 0)
        XCTAssertEqual(track.position(at: 0.5).x, 100, accuracy: 0.001)
        XCTAssertEqual(track.position(at: 1.5).x, 300, accuracy: 0.001)
        XCTAssertEqual(track.position(at: 1.5).y, 200, accuracy: 0.001)
    }

    func testSmoothingNeverMovesAStillCursor() {
        let track = CursorTrack(log: log([CursorEvent(t: 0, x: 420, y: 240, type: .move)]), duration: 3, smoothing: 1)
        for t in stride(from: 0.0, through: 3, by: 0.25) {
            XCTAssertEqual(track.position(at: t).x, 420, accuracy: 0.001)
            XCTAssertEqual(track.position(at: t).y, 240, accuracy: 0.001)
        }
    }

    func testSmoothingSoftensAJumpWithoutLagging() {
        let events = [
            CursorEvent(t: 0, x: 0, y: 0, type: .move),
            CursorEvent(t: 1, x: 100, y: 0, type: .move),
        ]
        let track = CursorTrack(log: log(events), duration: 2, smoothing: 1)
        // The blur looks both ways, so the jump is centred on the event (no lag).
        XCTAssertEqual(track.position(at: 1).x, 50, accuracy: 6)
        XCTAssertGreaterThan(track.position(at: 0.95).x, 0)
        XCTAssertLessThan(track.position(at: 1.05).x, 100)
        // Far from the jump it has fully settled.
        XCTAssertEqual(track.position(at: 0.5).x, 0, accuracy: 0.01)
        XCTAssertEqual(track.position(at: 1.5).x, 100, accuracy: 0.01)
        // It only ever moves forward.
        var previous = -1.0
        for t in stride(from: 0.7, through: 1.3, by: 0.01) {
            let x = track.position(at: t).x
            XCTAssertGreaterThanOrEqual(x, previous - 1e-9)
            previous = x
        }
    }

    func testTimesOutsideTheRecordingAreSafe() {
        let track = CursorTrack(log: log([CursorEvent(t: 0, x: 5, y: 6, type: .move)]), duration: 1, smoothing: 0.5)
        XCTAssertEqual(track.position(at: -3).x, 5, accuracy: 0.001)
        XCTAssertEqual(track.position(at: 999).x, 5, accuracy: 0.001)
    }

    func testAnEmptyLogStillWorks() {
        let track = CursorTrack(log: log([]), duration: 0, smoothing: 0.5)
        XCTAssertEqual(track.position(at: 0), .zero)
        XCTAssertEqual(track.shape(at: 0), 0)
        XCTAssertEqual(track.visibility(at: 0), 1)
        XCTAssertNil(track.timeSinceClick(at: 0))
    }

    func testClickAmountEasesOutOverAQuarterSecond() {
        let track = CursorTrack(log: log([
            CursorEvent(t: 0, x: 0, y: 0, type: .move),
            CursorEvent(t: 1, x: 0, y: 0, type: .leftDown),
        ]), duration: 3, smoothing: 0)
        XCTAssertEqual(track.clickAmount(at: 0.9), 0)
        XCTAssertEqual(track.clickAmount(at: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(track.clickAmount(at: 1.125), 0.25, accuracy: 1e-9)
        XCTAssertEqual(track.clickAmount(at: 1.25), 0, accuracy: 1e-9)
        XCTAssertEqual(track.timeSinceClick(at: 1.5)!, 0.5, accuracy: 1e-9)
        XCTAssertNil(track.timeSinceClick(at: 0.5))
    }

    func testCursorFadesAfterSittingStill() {
        let track = CursorTrack(log: log([
            CursorEvent(t: 0, x: 0, y: 0, type: .move),
            CursorEvent(t: 1, x: 50, y: 0, type: .move),
            CursorEvent(t: 1.2, x: 50.5, y: 0, type: .move),  // under a point: not real movement
        ]), duration: 10, smoothing: 0)
        XCTAssertEqual(track.visibility(at: 2.4), 1)
        XCTAssertEqual(track.visibility(at: 2.7), 0.5, accuracy: 1e-6)  // 1.5 s idle + half of the 0.4 s fade
        XCTAssertEqual(track.visibility(at: 3), 0)
    }

    func testShapeFollowsShapeEvents() {
        let track = CursorTrack(log: log([
            CursorEvent(t: 0, x: 0, y: 0, type: .move),
            CursorEvent(t: 1, x: 0, y: 0, type: .shape, shape: 3),
            CursorEvent(t: 2, x: 0, y: 0, type: .shape, shape: 0),
        ]), duration: 3, smoothing: 0)
        XCTAssertEqual(track.shape(at: 0.5), 0)
        XCTAssertEqual(track.shape(at: 1.5), 3)
        XCTAssertEqual(track.shape(at: 2.5), 0)
    }
}
