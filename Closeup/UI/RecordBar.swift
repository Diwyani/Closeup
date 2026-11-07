import SwiftUI

/// Bottom of the main window: last recording on the left, record button on the right.
struct RecordBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = appState.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack(alignment: .center) {
                if let last = appState.lastRecording {
                    LastRecordingView(result: last)
                } else {
                    Text("\(GlobalHotKey.toggleRecordingDisplay) starts and stops recording from anywhere.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RecordButton()
            }
        }
        .padding(16)
    }
}

private struct RecordButton: View {
    @Environment(AppState.self) private var appState

    private var title: String {
        switch appState.phase {
        case .idle: "Record"
        case .countdown: "Cancel"
        case .recording: "Stop"
        case .saving: "Saving…"
        }
    }

    var body: some View {
        Button(action: appState.toggleRecording) {
            HStack(spacing: 8) {
                if appState.phase == .idle {
                    Circle().fill(.white).frame(width: 10, height: 10)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                }
                Text(title)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.red, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(appState.phase == .saving || (appState.phase == .idle && appState.selection == nil))
        .help("Start or stop recording (\(GlobalHotKey.toggleRecordingDisplay))")
    }
}

private struct LastRecordingView: View {
    @Environment(AppState.self) private var appState
    let result: RecordingSession.Result

    private var summary: String {
        let m = result.metadata
        let duration = Duration.seconds(m.duration).formatted(.time(pattern: .minuteSecond))
        return "\(duration) · \(m.videoWidth)×\(m.videoHeight) · \(m.frameCount) frames"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Saved").font(.caption).foregroundStyle(.secondary)
            Text(summary).font(.callout.monospacedDigit())
            HStack(spacing: 12) {
                Button("Play") { appState.play(result.project) }
                Button("Show in Finder") { appState.reveal(result.project) }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }
}
