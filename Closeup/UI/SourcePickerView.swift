import ScreenCaptureKit
import SwiftUI

/// Pick a display (shown as live thumbnails) or a single window.
struct SourcePickerView: View {
    @Environment(AppState.self) private var appState
    @State private var mode: RecordingMetadata.SourceKind = .display

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Record", selection: $mode) {
                    Text("Display").tag(RecordingMetadata.SourceKind.display)
                    Text("Window").tag(RecordingMetadata.SourceKind.window)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)

                Spacer()

                Button {
                    Task { await appState.refreshSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh the list")
            }

            ScrollView {
                switch mode {
                case .display: displayGrid
                case .window: windowList
                }
            }
        }
        .padding(16)
        .onAppear {
            if case .window = appState.selection { mode = .window }
        }
        .onChange(of: mode) { _, newMode in selectFirst(of: newMode) }
    }

    private var displayGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(appState.sources.displays) { source in
                DisplayCard(source: source, isSelected: appState.selection == .display(source.id))
                    .onTapGesture { appState.selection = .display(source.id) }
            }
        }
    }

    private var windowList: some View {
        LazyVStack(spacing: 2) {
            ForEach(appState.sources.windows) { source in
                WindowRow(source: source, isSelected: appState.selection == .window(source.id))
                    .onTapGesture { appState.selection = .window(source.id) }
            }
            if appState.sources.windows.isEmpty {
                Text("No windows found. Open a window and press refresh.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
            }
        }
    }

    private func selectFirst(of kind: RecordingMetadata.SourceKind) {
        switch (kind, appState.selection) {
        case (.display, .display?), (.window, .window?): return
        case (.display, _): appState.selection = appState.sources.displays.first.map { .display($0.id) }
        case (.window, _): appState.selection = appState.sources.windows.first.map { .window($0.id) }
        }
    }
}

private struct DisplayCard: View {
    let source: DisplaySource
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisplayThumbnail(display: source.display)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .secondary.opacity(0.25),
                                      lineWidth: isSelected ? 3 : 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.callout.weight(.medium))
                Text("\(source.display.width) × \(source.display.height) pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A small screenshot of the display, so it's obvious which one is which.
private struct DisplayThumbnail: View {
    let display: SCDisplay
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(CGFloat(display.width) / CGFloat(display.height), contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .task(id: display.displayID) {
                image = try? await capture()
            }
    }

    private func capture() async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = 440
        config.height = Int(440 * Double(display.height) / Double(display.width))
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

private struct WindowRow: View {
    let source: WindowSource
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = source.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "macwindow").resizable().scaledToFit()
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(source.title).lineLimit(1)
                Text(source.appName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(source.window.frame.width)) × \(Int(source.window.frame.height))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }
}
