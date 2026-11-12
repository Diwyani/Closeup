import AVKit
import SwiftUI

/// Preview on the left, style inspector on the right.
struct ProjectEditorView: View {
    let project: RecordingProject
    @State private var model: ProjectEditorModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                EditorLayout(model: model)
            } else if let loadError {
                ContentUnavailableView(
                    "Can't open this recording", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(project.displayName)
        .toolbar {
            if let model {
                ToolbarItem(placement: .primaryAction) { ExportButton(model: model) }
            }
        }
        .task {
            // Files can take a moment to settle right after recording, so try a few times.
            for attempt in 1...4 {
                do {
                    model = try await ProjectEditorModel.load(project)
                    return
                } catch {
                    if attempt == 4 { loadError = "\(error.localizedDescription)\n\(error)" }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        .onDisappear { model?.player.pause() }
    }
}

/// The editor's main action: always visible at the top right. Opens the
/// export options; shows progress while exporting.
private struct ExportButton: View {
    @Bindable var model: ProjectEditorModel
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            if let progress = model.exportProgress {
                Label("Exporting \(progress.formatted(.percent.precision(.fractionLength(0))))",
                      systemImage: "square.and.arrow.up")
                    .monospacedDigit()
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderedProminent)
        .help("Export the finished video")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            Form {
                ExportControls(model: model)
            }
            .formStyle(.grouped)
            .frame(width: 340)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct EditorLayout: View {
    let model: ProjectEditorModel
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                PlayerView(player: model.player, still: model.stillFrame)
                    .aspectRatio(model.style.aspect.ratio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)

                EditorTimeline(model: model)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            StyleInspector(model: model)
                .frame(width: 300)
        }
        .onAppear { keyMonitor = Self.monitorKeys(for: model) }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    }

    /// Editor keys: Space plays and pauses, I and O set the trim start and
    /// end to the playhead. Ignored while you're typing in a text field.
    private static func monitorKeys(for model: ProjectEditorModel) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText)
            else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": model.togglePlay()
            case "i": model.setTrimStart(model.currentTime)
            case "o": model.setTrimEnd(model.currentTime)
            default: return event
            }
            return nil
        }
    }
}

/// AppKit's AVPlayerView wrapped for SwiftUI. (SwiftUI's own VideoPlayer
/// crashes on this macOS version, so we use the AppKit one directly.)
///
/// `still` (a redrawn frame while paused) sits between the video and the
/// player's controls, so the controls keep working.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let still: CGImage?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        if let overlay = view.contentOverlayView {
            overlay.wantsLayer = true
            let layer = CALayer()
            layer.contentsGravity = .resizeAspect
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.frame = overlay.bounds
            overlay.layer?.addSublayer(layer)
            context.coordinator.stillLayer = layer
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        guard let layer = context.coordinator.stillLayer else { return }
        // A quick, soft crossfade between redraws: you see that something
        // changed without a jump. Back to the video (playing) is instant.
        if still != nil, layer.contents != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "contents")
            layer.contents = still
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = still
            CATransaction.commit()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var stillLayer: CALayer?
    }
}
