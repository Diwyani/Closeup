import SwiftUI

/// Shown until Screen Recording access is granted. Walks the user through
/// the three steps macOS makes them do.
struct PermissionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 6) {
                Text("Closeup needs Screen Recording access")
                    .font(.title2.weight(.semibold))
                Text("macOS asks you to allow this once. Recordings stay on your Mac.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                step(1, "Ask macOS for access", button: "Request Access") {
                    ScreenRecordingPermission.request()
                    appState.refreshPermission()
                }
                step(2, "Turn on Closeup in Privacy & Security → Screen & System Audio Recording",
                     button: "Open System Settings") {
                    ScreenRecordingPermission.openSystemSettings()
                }
                step(3, "Relaunch so macOS applies the change", button: "Relaunch Closeup") {
                    ScreenRecordingPermission.relaunchApp()
                }
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, _ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                Button(button, action: action)
            }
        }
    }
}
