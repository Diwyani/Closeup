import CoreMedia

/// The single clock both the video and the cursor log are measured against.
///
/// ScreenCaptureKit stamps every frame with the system "host time" clock. If
/// the cursor logger reads the very same clock, syncing the two is just a
/// subtraction: `cursorTime - firstFrameTime`.
enum HostClock {
    /// Seconds on the host clock (time since boot, not wall-clock time).
    static var now: Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}
