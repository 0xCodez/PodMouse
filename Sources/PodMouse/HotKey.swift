import Carbon.HIToolbox

/// A global keyboard shortcut.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var isInstalled = false
    private var reference: EventHotKeyRef?

    init(id: UInt32, keyCode: Int, handler: @escaping () -> Void) {
        Self.installOnce()
        Self.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x504D5345), id: id)
        RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &reference)
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
    }

    private static func installOnce() {
        guard !isInstalled else { return }
        isInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKey.handlers[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
