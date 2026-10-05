import Carbon.HIToolbox

/// A keyboard shortcut that works from any app (Teams, Meet, WhatsApp…).
/// Carbon hot keys need no Accessibility permission.
final class HotKey {
    static let label = "⌃⌥A"
    /// "So, what are they talking about?"
    static let catchUpLabel = "⌃⌥S"
    /// "Help me now": pause and explain, like right ⌥⌥.
    static let nowLabel = "⌃⌥D"
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void

    /// Control + Option + a key (A by default). Returns nil if another app already uses it.
    init?(key: Int = kVK_ANSI_A, id: UInt32 = 1, action: @escaping () -> Void) {
        self.id = id
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            // Every hot key's handler sees every press: only answer to our own.
            guard status == noErr, pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            hotKey.action()
            return noErr
        }, 1, &spec, me, &handler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x6173_6169), id: id) // "asai"
        let registered = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
        if installed != noErr || registered != noErr { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
