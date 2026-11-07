import Carbon.HIToolbox

/// A keyboard shortcut that works even when Closeup isn't the front app.
///
/// Carbon's RegisterEventHotKey is old, but it's still the standard way to do
/// this: it needs no Accessibility permission and only sees its own shortcut
/// (unlike a global key monitor, which would see every keystroke).
@MainActor
final class GlobalHotKey {
    /// ⌥⇧⌘R
    static let toggleRecordingDisplay = "⌥⇧⌘R"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Lives as long as the app, so there's no unregister step.
    init(keyCode: Int = kVK_ANSI_R, modifiers: Int = cmdKey | optionKey | shiftKey, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                // A C callback can't capture Swift values, so `self` rides along as userData.
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x5153_5452), id: 1)  // "QSTR"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
