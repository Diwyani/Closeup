import XCTest

/// The cursor log: turning raw mouse events into video time, and reading and
/// writing cursor.json.
@MainActor
final class CursorLogTests: XCTestCase {
    private func raw(_ time: Double, _ x: Double, _ y: Double, _ type: CursorEvent.Kind = .move, shape: Int? = nil) -> CursorLogger.RawEvent {
        CursorLogger.RawEvent(hostTime: time, position: CGPoint(x: x, y: y), type: type, shape: shape)
    }

    func testEventsAreRetimedSoTheFirstVideoFrameIsZero() {
        let events = RecordingSession.videoTimeline(
            [raw(100.5, 10, 20), raw(101.25, 30, 40, .leftDown)], videoStart: 100, videoEnd: 110)
        XCTAssertEqual(events.map(\.t), [0.5, 1.25])
        XCTAssertEqual(events[1].type, .leftDown)
        XCTAssertEqual(events[1].x, 30)
    }

    func testEventsBeforeTheFirstFrameCollapseIntoOneStartingPosition() {
        let events = RecordingSession.videoTimeline(
            [raw(98, 1, 1), raw(99, 5, 6, .shape, shape: 2), raw(99.5, 7, 8), raw(100.2, 9, 9)],
            videoStart: 100, videoEnd: 110)
        // Last known position before the video, and the last shape, both at t = 0.
        XCTAssertEqual(events[0], CursorEvent(t: 0, x: 7, y: 8, type: .move))
        XCTAssertEqual(events[1], CursorEvent(t: 0, x: 7, y: 8, type: .shape, shape: 2))
        XCTAssertEqual(events[2].t, 0.2, accuracy: 1e-9)
        XCTAssertEqual(events.count, 3)
    }

    func testEventsAfterTheVideoEndsAreDropped() {
        let events = RecordingSession.videoTimeline(
            [raw(100.5, 1, 1), raw(110.5, 2, 2)], videoStart: 100, videoEnd: 110)
        XCTAssertEqual(events.count, 1)
    }

    func testNoEventsGivesAnEmptyLog() {
        XCTAssertTrue(RecordingSession.videoTimeline([], videoStart: 100, videoEnd: 110).isEmpty)
    }

    func testEventValuesAreRoundedForReadableJSON() {
        let event = CursorEvent(t: 1.23456789, x: 10.126, y: 20.124, type: .move)
        XCTAssertEqual(event.t, 1.2346)
        XCTAssertEqual(event.x, 10.13)
        XCTAssertEqual(event.y, 20.12)
    }

    func testIsClickCoversEveryButtonDownOnly() {
        let clicks: [CursorEvent.Kind] = [.leftDown, .rightDown, .otherDown]
        let others: [CursorEvent.Kind] = [.move, .leftUp, .rightUp, .otherUp, .shape, .typing]
        for kind in clicks { XCTAssertTrue(CursorEvent(t: 0, x: 0, y: 0, type: kind).isClick) }
        for kind in others { XCTAssertFalse(CursorEvent(t: 0, x: 0, y: 0, type: kind).isClick) }
    }

    func testCursorLogSurvivesSavingAndLoading() throws {
        let log = CursorLog(
            scale: 2, width: 1440, height: 900,
            shapes: [CursorShape(id: 1, file: "1.png", width: 16, height: 16, hotspotX: 4, hotspotY: 4)],
            events: [
                CursorEvent(t: 0, x: 1, y: 2, type: .move),
                CursorEvent(t: 0.5, x: 3, y: 4, type: .shape, shape: 1),
                CursorEvent(t: 1, x: 3, y: 4, type: .typing),
            ])
        let decoded = try JSONDecoder().decode(CursorLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(decoded.events, log.events)
        XCTAssertEqual(decoded.shapes, log.shapes)
        XCTAssertEqual(decoded.scale, 2)
        XCTAssertEqual(decoded.version, 1)
    }

    /// A cursor.json exactly as version 1 of the app wrote it. If this stops
    /// loading, old recordings stop opening.
    func testReadsACursorLogWrittenByVersion1() throws {
        let json = #"{"version":1,"scale":2,"width":1440,"height":900,"events":[{"t":0,"x":10,"y":20,"type":"move"},{"t":0.4,"x":10,"y":20,"type":"leftDown"}]}"#
        let log = try JSONDecoder().decode(CursorLog.self, from: Data(json.utf8))
        XCTAssertEqual(log.events.count, 2)
        XCTAssertNil(log.shapes)
        XCTAssertTrue(log.events[1].isClick)
    }
}
