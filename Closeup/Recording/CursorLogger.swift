import AppKit

/// Logs where the mouse is, when it clicks, and what shape the cursor has,
/// while recording.
///
/// Uses NSEvent monitors, which see mouse events without the Accessibility
/// permission. (Keystrokes will need it; that's a later phase.)
@MainActor
final class CursorLogger {
    struct RawEvent: Codable {
        /// Host-clock seconds; turned into video time when the recording is saved.
        let hostTime: Double
        /// Points from the top-left of the captured area.
        let position: CGPoint
        let type: CursorEvent.Kind
        var shape: Int?
    }

    /// Top-left of the captured area in global points, right now.
    private let contentOrigin: () -> CGPoint
    private let shapesFolder: URL
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    /// The system's running count of key presses. Reading it needs no
    /// permission and reveals nothing about which keys were pressed.
    private var lastKeyCount: UInt32 = 0
    private var events: [RawEvent] = []

    // Kept on disk as we go, so a crash doesn't lose the cursor (see RecordingRecovery).
    private let journalURL: URL?
    private let shapesJournalURL: URL?
    private var journal: CursorJournal?
    private var journaledCount = 0
    private var ticks = 0

    // Cursor shapes. Each new look gets an id and a PNG; the same look seen
    // again reuses its id.
    private static let arrowImageData = NSCursor.arrow.image.tiffRepresentation
    private var shapeIDs: [Data: Int] = [:]
    private var shapes: [CursorShape] = []
    private var currentShape: Int?
    private var lastShapeCheck = 0.0

    init(target: CaptureTarget, shapesFolder: URL, journalURL: URL? = nil, shapesJournalURL: URL? = nil) {
        contentOrigin = Self.contentOrigin(for: target)
        self.shapesFolder = shapesFolder
        self.journalURL = journalURL
        self.shapesJournalURL = shapesJournalURL
    }

    /// Adds the events since last time to the file on disk.
    private func writeJournal() {
        guard let journal, journaledCount < events.count else { return }
        journal.append(events[journaledCount...])
        journaledCount = events.count
    }

    func start() {
        events.removeAll(keepingCapacity: true)
        journaledCount = 0
        journal = journalURL.flatMap(CursorJournal.init(url:))
        // Know where the cursor is, and what it looks like, before it moves.
        record(.move)
        checkShape(force: true)

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
        ]
        // Global monitors see events headed to other apps; local ones see
        // events in our own windows. Together they see everything.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(monitor)
        }
        // Every 0.1 s: the shape can change while the mouse stands still (e.g. a
        // page loads under it), and typing doesn't move the mouse at all.
        lastKeyCount = Self.keyPressCount
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkShape()
                self.checkTyping()
                // Every 2 s.
                self.ticks += 1
                if self.ticks % 20 == 0 { self.writeJournal() }
            }
        }
    }

    func stop() -> (events: [RawEvent], shapes: [CursorShape]) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        writeJournal()
        journal?.close()
        journal = nil
        return (events, shapes)
    }

    // MARK: Typing

    private static var keyPressCount: UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    }

    /// Logs a `.typing` event if any key was pressed since the last check,
    /// so auto-zoom can zoom in while you type.
    private func checkTyping() {
        let count = Self.keyPressCount
        guard count != lastKeyCount else { return }
        lastKeyCount = count
        record(.typing)
    }

    private func handle(_ event: NSEvent) {
        guard let kind = CursorEvent.Kind(event.type) else { return }
        record(kind)
        checkShape()
    }

    private func record(_ kind: CursorEvent.Kind, shape: Int? = nil) {
        // Read the clock first, as close to the event as possible.
        let time = HostClock.now
        let mouse = ScreenGeometry.mouseLocation
        let origin = contentOrigin()
        events.append(RawEvent(
            hostTime: time,
            position: CGPoint(x: mouse.x - origin.x, y: mouse.y - origin.y),
            type: kind,
            shape: shape))
    }

    // MARK: Cursor shapes

    /// Logs a `.shape` event when the system cursor looks different from
    /// before. Checks at most 20× a second.
    private func checkShape(force: Bool = false) {
        let now = HostClock.now
        guard force || now - lastShapeCheck >= 0.05 else { return }
        lastShapeCheck = now

        guard let cursor = NSCursor.currentSystem, let data = cursor.image.tiffRepresentation else { return }
        let id = shapeID(for: cursor, imageData: data)
        guard id != currentShape else { return }
        currentShape = id
        record(.shape, shape: id)
    }

    private func shapeID(for cursor: NSCursor, imageData: Data) -> Int {
        if let id = shapeIDs[imageData] { return id }

        var id = 0  // the standard arrow, or a shape we couldn't save
        if imageData != Self.arrowImageData {
            let candidate = shapes.count + 1
            let file = "\(candidate).png"
            if Self.savePNG(cursor.image, to: shapesFolder.appending(path: file)) {
                id = candidate
                shapes.append(CursorShape(
                    id: id, file: file,
                    width: cursor.image.size.width, height: cursor.image.size.height,
                    hotspotX: cursor.hotSpot.x, hotspotY: cursor.hotSpot.y))
                if let shapesJournalURL, let data = try? JSONEncoder().encode(shapes) {
                    try? data.write(to: shapesJournalURL, options: .atomic)
                }
            }
        }
        shapeIDs[imageData] = id
        return id
    }

    /// Saves at the image's best resolution (at least 2×, so it stays crisp when enlarged).
    private static func savePNG(_ image: NSImage, to url: URL) -> Bool {
        let bestPixelWidth = image.representations.map(\.pixelsWide).max() ?? 0
        let scale = min(4, max(2, CGFloat(bestPixelWidth) / max(1, image.size.width)))
        guard
            image.size.width > 0,
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }

        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: Coordinates

    private static func contentOrigin(for target: CaptureTarget) -> () -> CGPoint {
        guard target.kind == .window, let windowID = target.windowID else {
            let origin = target.frame.origin
            return { origin }
        }
        // Windows can move mid-recording, so re-read the window position, at
        // most 10× a second (it's a cheap system call, but not free).
        var origin = target.frame.origin
        var lastCheck = 0.0
        return {
            let now = HostClock.now
            if now - lastCheck > 0.1 {
                lastCheck = now
                if let frame = ScreenGeometry.currentFrame(ofWindow: windowID) {
                    origin = frame.origin
                }
            }
            return origin
        }
    }
}

private extension CursorEvent.Kind {
    init?(_ type: NSEvent.EventType) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: self = .move
        case .leftMouseDown: self = .leftDown
        case .leftMouseUp: self = .leftUp
        case .rightMouseDown: self = .rightDown
        case .rightMouseUp: self = .rightUp
        case .otherMouseDown: self = .otherDown
        case .otherMouseUp: self = .otherUp
        default: return nil
        }
    }
}
