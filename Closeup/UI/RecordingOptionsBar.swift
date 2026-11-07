import SwiftUI

/// Camera, microphone and system-audio choices, between the source picker
/// and the record button.
struct RecordingOptionsBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 18) {
            Picker(selection: $appState.selectedCameraID) {
                Text("No camera").tag(String?.none)
                ForEach(appState.cameras, id: \.uniqueID) { camera in
                    Text(camera.localizedName).tag(Optional(camera.uniqueID))
                }
            } label: {
                Image(systemName: "web.camera")
            }
            .help("Camera for the face bubble")
            .fixedSize()

            Picker(selection: $appState.selectedMicrophoneID) {
                Text("No microphone").tag(String?.none)
                ForEach(appState.microphones, id: \.uniqueID) { microphone in
                    Text(microphone.localizedName).tag(Optional(microphone.uniqueID))
                }
            } label: {
                Image(systemName: "mic")
            }
            .help("Microphone for your voice")
            .fixedSize()

            Toggle(isOn: $appState.recordsSystemAudio) {
                Label("System audio", systemImage: "speaker.wave.2")
            }
            .help("Record what your Mac plays")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(appState.phase != .idle)
    }
}
