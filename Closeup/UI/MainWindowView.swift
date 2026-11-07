import SwiftUI

/// Sidebar with "New Recording" and every saved recording; the detail side
/// shows the recorder or the editor for the selected recording.
struct MainWindowView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            List(selection: $appState.sidebarSelection) {
                Label("New Recording", systemImage: "record.circle")
                    .tag(SidebarItem.recorder)

                Section("Recordings") {
                    ForEach(appState.projects) { project in
                        Label(project.displayName, systemImage: "film")
                            .tag(SidebarItem.project(project))
                            .contextMenu {
                                Button("Show in Finder") { appState.reveal(project) }
                                Divider()
                                Button("Move to Trash", role: .destructive) { appState.moveToTrash(project) }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            switch appState.sidebarSelection {
            case .project(let project):
                ProjectEditorView(project: project)
                    .id(project)  // a fresh editor per recording
            case .recorder, nil:
                RecorderView()
            }
        }
        .frame(minWidth: 960, minHeight: 620)
    }
}

/// The Phase 1 recorder screen.
struct RecorderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if appState.permissionGranted {
                SourcePickerView()
                Divider()
                RecordingOptionsBar()
                Divider()
                RecordBar()
            } else {
                PermissionView()
            }
        }
        .navigationTitle("New Recording")
    }
}
