import AppKit
import Observation
import SwiftUI

/// The big 3-2-1 that floats in the middle of the screen being recorded.
///
/// It's a borderless, click-through NSPanel hosting a SwiftUI view. Since
/// display recordings exclude Closeup's own windows, it never ends up
/// in the video.
@MainActor
final class CountdownOverlay {
    @Observable
    final class Model {
        var number = 3
    }

    private let model = Model()
    private lazy var panel = makePanel()
    private let size = CGSize(width: 180, height: 180)

    func show(_ number: Int, on screen: NSScreen?) {
        model.number = number
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        return panel
    }
}

private struct CountdownView: View {
    let model: CountdownOverlay.Model

    var body: some View {
        Text("\(model.number)")
            .font(.system(size: 96, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .frame(width: 180, height: 180)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
            .animation(.snappy, value: model.number)
    }
}
