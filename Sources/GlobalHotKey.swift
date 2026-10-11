import Carbon

/// Thin wrapper over Carbon's RegisterEventHotKey for system-wide hotkeys.
/// Works without accessibility permissions; the event is consumed so it
/// won't reach the focused app.
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        let id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        self.id = id
        GlobalHotKey.handlers[id] = handler
        GlobalHotKey.installHandlerIfNeeded()

        let signature: OSType = 0x666f6373 // 'focs'
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            GlobalHotKey.handlers.removeValue(forKey: id)
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        GlobalHotKey.handlers.removeValue(forKey: id)
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                guard let event else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                let id = hkID.id
                DispatchQueue.main.async { GlobalHotKey.handlers[id]?() }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
    }

    // MARK: - Convenience constants

    static let spaceKey: UInt32     = UInt32(kVK_Space)
    static let pKey: UInt32         = UInt32(kVK_ANSI_P)
    static let sKey: UInt32         = UInt32(kVK_ANSI_S)
    static let aKey: UInt32         = UInt32(kVK_ANSI_A)
    static let bKey: UInt32         = UInt32(kVK_ANSI_B)
    static let rKey: UInt32         = UInt32(kVK_ANSI_R)
    static let digitKeys: [UInt32]  = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
        kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ].map { UInt32($0) }
    static let controlModifier: UInt32 = UInt32(controlKey)
    static let optionModifier: UInt32  = UInt32(optionKey)
    static let commandModifier: UInt32 = UInt32(cmdKey)
    static let shiftModifier: UInt32   = UInt32(shiftKey)
}
