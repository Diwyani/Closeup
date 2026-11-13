import XCTest

/// Automatic zooms from clicks and typing, and the camera's easing.
final class ZoomTests: XCTestCase {
    private let screen = CGSize(width: 1000, height: 600)

    private func log(_ events: [CursorEvent]) -> CursorLog {
        CursorLog(scale: 2, width: 1000, height: 600, events: events)
    }

    private func click(_ t: Double, _ x: Double = 500, _ y: Double = 300) -> CursorEvent {
        CursorEvent(t: t, x: x, y: y, type: .leftDown)
    }

    // MARK: Activities

    func testClicksBecomeActivitiesAndMovesDoNot() {
        let activities = ZoomPlanner.activities(from: log([
            CursorEvent(t: 0, x: 0, y: 0, type: .move), click(1, 10, 20),
            CursorEvent(t: 1.1, x: 10, y: 20, type: .leftUp),
            CursorEvent(t: 2, x: 30, y: 40, type: .rightDown),
        ]), duration: 10, includeTyping: true)
        XCTAssertEqual(activities.map(\.time), [1, 2])
        XCTAssertEqual(activities[0].focus, CGPoint(x: 10, y: 20))
        XCTAssertFalse(activities[0].isTyping)
    }

    func testTypingFocusesOnTheLastClickNotTheMouse() {
        let activities = ZoomPlanner.activities(from: log([
            click(1, 100, 200),
            CursorEvent(t: 3, x: 900, y: 500, type: .typing),   // mouse wandered off
            CursorEvent(t: 20, x: 900, y: 500, type: .typing),  // the click is too old now
        ]), duration: 30, includeTyping: true)
        XCTAssertEqual(activities[1].focus, CGPoint(x: 100, y: 200))
        XCTAssertTrue(activities[1].isTyping)
        XCTAssertEqual(activities[2].focus, CGPoint(x: 900, y: 500))
    }

    func testTypingIsIgnoredWhenTurnedOffOrInTheLastSecond() {
        let events = [CursorEvent(t: 2, x: 0, y: 0, type: .typing), CursorEvent(t: 9.5, x: 0, y: 0, type: .typing)]
        XCTAssertTrue(ZoomPlanner.activities(from: log(events), duration: 10, includeTyping: false).isEmpty)
        // The stop shortcut at the very end shouldn't cause a zoom.
        XCTAssertEqual(ZoomPlanner.activities(from: log(events), duration: 10, includeTyping: true).map(\.time), [2])
    }

    // MARK: Segments

    private func segments(_ times: [Double], typing: Set<Double> = [], duration: Double = 60) -> [ZoomSegment] {
        ZoomPlanner.segments(
            for: times.map { ZoomActivity(time: $0, focus: .zero, isTyping: typing.contains($0)) },
            duration: duration, scale: 2, typingScale: 3)
    }

    func testOneClickMakesOneZoomAroundIt() {
        let result = segments([10])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, 10 - ZoomPlanner.lead, accuracy: 1e-9)
        XCTAssertEqual(result[0].end, 10 + ZoomPlanner.hold, accuracy: 1e-9)
        XCTAssertEqual(result[0].scale, 2)
    }

    func testClicksCloseTogetherShareOneZoom() {
        let result = segments([10, 12, 14.5])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].end, 16, accuracy: 1e-9)
    }

    func testClicksFarApartGetSeparateZooms() {
        let result = segments([10, 20])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].start, 19.5, accuracy: 1e-9)
    }

    func testZoomsNeverRunPastTheRecording() {
        XCTAssertEqual(segments([0.2])[0].start, 0)
        XCTAssertEqual(segments([59.5])[0].end, 60)
    }

    func testAZoomWithTypingInItUsesTheCloserTypingLevel() {
        let result = segments([10, 11], typing: [11])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].scale, 3)
    }

    func testActivitiesAreSortedFirst() {
        XCTAssertEqual(segments([20, 10]).map(\.start), [9.5, 19.5])
    }

    func testNoActivityMeansNoZoom() {
        XCTAssertTrue(segments([]).isEmpty)
    }

    // MARK: Where a zoom looks

    func testSteadyZoomCentresOnEverythingClickedIfItFits() {
        let segment = ZoomSegment(start: 0, end: 10, scale: 2)
        let near = [ZoomActivity(time: 1, focus: CGPoint(x: 100, y: 100), isTyping: false),
                    ZoomActivity(time: 2, focus: CGPoint(x: 300, y: 200), isTyping: false)]
        XCTAssertEqual(ZoomPlanner.steadyCenter(for: segment, activities: near, screenSize: screen), CGPoint(x: 200, y: 150))

        // 2× zoom shows 500 pt across; 80% of that is 400. These are 700 apart.
        let far = near + [ZoomActivity(time: 3, focus: CGPoint(x: 800, y: 100), isTyping: false)]
        XCTAssertNil(ZoomPlanner.steadyCenter(for: segment, activities: far, screenSize: screen))
    }

    func testAnchorPrefersYourChoiceThenFollowCursorThenAutomatic() {
        var segment = ZoomSegment(start: 0, end: 10, scale: 2)
        let activities = [ZoomActivity(time: 1, focus: CGPoint(x: 100, y: 100), isTyping: false)]
        XCTAssertEqual(ZoomPlanner.anchor(for: segment, activities: activities, screenSize: screen), CGPoint(x: 100, y: 100))
        segment.focus = CGPoint(x: 0.5, y: 0.25)
        XCTAssertEqual(ZoomPlanner.anchor(for: segment, activities: activities, screenSize: screen), CGPoint(x: 500, y: 150))
        segment.followsCursor = true
        XCTAssertNil(ZoomPlanner.anchor(for: segment, activities: activities, screenSize: screen))
    }

    // MARK: Camera easing

    private func camera(_ segments: [ZoomSegment], cursorAt point: CGPoint = CGPoint(x: 500, y: 300), speed: Double = 1) -> CameraTrack {
        let cursor = CursorTrack(
            log: log([CursorEvent(t: 0, x: point.x, y: point.y, type: .move)]), duration: 20, smoothing: 0)
        let activities = [ZoomActivity(time: 5.5, focus: point, isTyping: false)]
        return CameraTrack(segments: segments, activities: activities, cursor: cursor, screenSize: screen, duration: 20, speed: speed)
    }

    func testCameraStartsZoomedOutAndReachesTheZoomLevel() {
        let track = camera([ZoomSegment(start: 5, end: 10, scale: 2)])
        XCTAssertEqual(track.camera(at: 0).zoom, 1, accuracy: 1e-6)
        XCTAssertEqual(track.camera(at: 4.9).zoom, 1, accuracy: 1e-6)
        XCTAssertEqual(track.camera(at: 9.5).zoom, 2, accuracy: 0.01)
        XCTAssertEqual(track.camera(at: 19).zoom, 1, accuracy: 0.01)
    }

    func testZoomEasesSmoothlyWithoutOvershootOrJumps() {
        let track = camera([ZoomSegment(start: 5, end: 10, scale: 2)])
        var previous = track.camera(at: 0).zoom
        for step in 1...(20 * 120) {
            let zoom = track.camera(at: Double(step) / 120).zoom
            XCTAssertGreaterThanOrEqual(zoom, 1 - 1e-3, "zoomed out past the whole screen")
            XCTAssertLessThanOrEqual(zoom, 2 + 1e-3, "overshot the zoom level")
            XCTAssertLessThan(abs(zoom - previous), 0.03, "zoom jumped between two samples")
            previous = zoom
        }
        // Half a second in, it is clearly on its way but not there yet.
        let early = track.camera(at: 5.25).zoom
        XCTAssertGreaterThan(early, 1.05)
        XCTAssertLessThan(early, 1.95)
    }

    func testFasterZoomSpeedGetsThereSooner() {
        let slow = camera([ZoomSegment(start: 5, end: 10, scale: 2)], speed: 0.5)
        let fast = camera([ZoomSegment(start: 5, end: 10, scale: 2)], speed: 2)
        XCTAssertGreaterThan(fast.camera(at: 5.3).zoom, slow.camera(at: 5.3).zoom)
    }

    func testASteadyZoomNearACornerStaysInsideTheScreen() {
        let corner = CGPoint(x: 990, y: 590)
        let track = camera([ZoomSegment(start: 5, end: 10, scale: 2)], cursorAt: corner)
        let center = track.camera(at: 9.5).center
        // At 2× the view is 500×300, so its centre can go no further than (750, 450).
        XCTAssertEqual(center.x, 750, accuracy: 1)
        XCTAssertEqual(center.y, 450, accuracy: 1)
    }

    func testCameraLookupOutsideTheRecordingIsSafe() {
        let track = camera([])
        XCTAssertEqual(track.camera(at: -5).zoom, 1, accuracy: 1e-6)
        XCTAssertEqual(track.camera(at: 500).zoom, 1, accuracy: 1e-6)
    }
}
