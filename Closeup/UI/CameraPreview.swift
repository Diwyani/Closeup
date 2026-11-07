import AppKit
import CoreVideo

/// A small live view of the webcam while recording, so you can see how you
/// look. It floats above everything; drag it anywhere, click it to switch
/// between a circle and a rounded square.
///
/// It shows the very frames being recorded (it doesn't touch the camera
/// itself). Like the countdown, it's one of Closeup's own windows, so
/// display recordings leave it out: the real bubble is added in the editor.
final class CameraPreview: @unchecked Sendable {
    private var panel: NSPanel?
    private var view: PreviewView?
    private let size: CGFloat = 180
    /// Remembered between recordings.
    private var isCircle: Bool {
        get { UserDefaults.standard.object(forKey: "previewIsCircle") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "previewIsCircle") }
    }

    @MainActor
    func show(on screen: NSScreen?) {
        hide()
        let view = PreviewView()
        view.onClick = { [weak self, weak view] in
            guard let self, let view else { return }
            isCircle.toggle()
            view.setCircle(isCircle, size: size)
        }
        view.setCircle(isCircle, size: size)

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        // Bottom-right corner, like the bubble's default spot.
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visible.maxX - size - 24, y: visible.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
    }

    /// Called from the camera queue with each frame.
    nonisolated func display(_ frame: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [self] in
            view?.image.contents = surface
        }
    }

    @MainActor
    func hide() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }
}

private final class PreviewView: NSView {
    var onClick: (() -> Void)?
    /// The camera picture, mirrored like a mirror.
    let image = CALayer()
    private var mouseDownLocation: CGPoint = .zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.borderWidth = 3
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        image.contentsGravity = .resizeAspectFill
        image.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(image)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCircle(_ circle: Bool, size: CGFloat) {
        layer?.cornerRadius = circle ? size / 2 : size * 0.18
    }

    override func layout() {
        super.layout()
        image.frame = bounds
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        // A click, not the end of a drag.
        if hypot(NSEvent.mouseLocation.x - mouseDownLocation.x, NSEvent.mouseLocation.y - mouseDownLocation.y) < 3 {
            onClick?()
        }
        super.mouseUp(with: event)
    }
}
