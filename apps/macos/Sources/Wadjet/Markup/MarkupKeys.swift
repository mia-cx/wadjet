import AppKit
import Carbon

/// Markup's command keys (⌘Z ⇧⌘Z undo, ⌘] ⌘[ ⇧⌘] ⇧⌘[ restack, ⌘⌥L Layers,
/// ⌘V paste) as Carbon hot keys, registered while the toolbar is open — the
/// same seam Escape uses — so the apps underneath keep their own undo the
/// rest of the time. Keys follow the current keyboard layout: a character
/// means wherever that character is typed, not the ANSI key position (Z sits
/// where US has Y on German QWERTZ).
@MainActor
final class MarkupKeys {
    static let shared = MarkupKeys()
    /// 'wmky'; Escape/Measure/Space use 'wdjt' — each handler passes through foreign signatures
    private static let signature = OSType(0x776D6B79)
    /// the character the key types unmodified, its ANSI fallback, Carbon
    /// modifiers, action — hot key id = row index, so the next slice just appends rows
    private static let keys: [(character: Character, fallback: Int, modifiers: Int, action: @MainActor () -> Void)] = [
        ("z", kVK_ANSI_Z, cmdKey, { MarkupController.shared.undo() }),
        ("z", kVK_ANSI_Z, cmdKey | shiftKey, { MarkupController.shared.redo() }),
        ("]", kVK_ANSI_RightBracket, cmdKey, { MarkupController.shared.restackSelection(.up) }),
        ("[", kVK_ANSI_LeftBracket, cmdKey, { MarkupController.shared.restackSelection(.down) }),
        ("]", kVK_ANSI_RightBracket, cmdKey | shiftKey, { MarkupController.shared.restackSelection(.front) }),
        ("[", kVK_ANSI_LeftBracket, cmdKey | shiftKey, { MarkupController.shared.restackSelection(.back) }),
        ("l", kVK_ANSI_L, cmdKey | optionKey, { LayersWindow.shared.toggle() }),
        ("v", kVK_ANSI_V, cmdKey, {
            if !MarkupController.shared.paste(from: .general, at: NSEvent.mouseLocation) { NSSound.beep() }
        }),
    ]
    private var refs: [EventHotKeyRef] = []
    private var registered = false
    private var handlerInstalled = false
    private init() {
        // a layout change moves the characters our hot keys mean; re-resolve
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { _ in
                Task { @MainActor in MarkupKeys.shared.relayout() }
            }
    }

    /// register while the toolbar is open, unregister when it closes; no-op when unchanged
    func sync(active: Bool) {
        guard active != registered else { return }
        if active { register() } else { unregister() }
    }

    /// the key code that types `character` with Command held in the current
    /// keyboard layout, or nil — Carbon hot keys match key codes, which are
    /// physical positions (Z sits where US has Y on German QWERTZ), and layouts
    /// with a Command-specific map ("Dvorak - QWERTY ⌘") move the shortcut's key
    private static func keyCode(typing character: Character) -> Int? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let want = String(character)
        return data.withUnsafeBytes { buf -> Int? in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let err = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown),
                                         UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                                         OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                if err == noErr, String(utf16CodeUnits: chars, count: length).lowercased() == want { return code }
            }
            return nil
        }
    }

    private func register() {
        if !handlerInstalled {
            handlerInstalled = true
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ -> OSStatus in
                var id = EventHotKeyID()
                GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == OSType(0x776D6B79) else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { MarkupKeys.shared.fire(Int(id.id)) }
                return noErr
            }, 1, &type, nil, nil)
        }
        for (i, k) in Self.keys.enumerated() {
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(UInt32(Self.keyCode(typing: k.character) ?? k.fallback), UInt32(k.modifiers),
                                          EventHotKeyID(signature: Self.signature, id: UInt32(i)),
                                          GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
            if err != noErr { AppLog.line("markup keys: hot key \(i) err=\(err)") }
        }
        registered = true
        AppLog.line("markup keys registered")
    }

    private func unregister() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        registered = false
        AppLog.line("markup keys unregistered")
    }

    /// the keyboard layout changed: re-resolve while registered, else nothing
    private func relayout() {
        guard registered else { return }
        sync(active: false); sync(active: true)
    }

    fileprivate func fire(_ index: Int) {
        guard Self.keys.indices.contains(index) else { return }
        Self.keys[index].action()
    }
}
