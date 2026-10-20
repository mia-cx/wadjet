import AppKit
import Carbon
import WadjetKit

/// Markup's command keys (⌘Z ⇧⌘Z undo, ⌘] ⌘[ ⇧⌘] ⇧⌘[ restack, ⌘⌥L Layers,
/// ⌘V paste) as Carbon hot keys — the same seam Escape uses — and the
/// unmodified Markup Tool Keys (V Select, P Pen, R Rectangle, …) as a local
/// key monitor, so the apps underneath keep their own keys the rest of the
/// time. Command keys are live while the toolbar is open; the letters only
/// while a Freeze Frame is up or a Markup Tool is armed. Both suspend while
/// typing lives on a Markup surface. Keys follow the current keyboard layout:
/// a character means wherever that character is typed, not the ANSI key
/// position (Z sits where US has Y on German QWERTZ).
@MainActor
final class MarkupKeys {
    static let shared = MarkupKeys()
    /// 'wmky'; Escape/Measure/Space use 'wdjt' — each handler passes through foreign signatures
    private static let signature = OSType(0x776D6B79)
    /// the character the key types unmodified, its ANSI fallback, Carbon
    /// modifiers, action — hot key id = row index
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
    private var commandRefs: [EventHotKeyRef] = []
    private var toolMonitor: Any?
    private var commandsRegistered = false
    private var toolsRegistered = false
    private var handlerInstalled = false
    private init() {
        // a layout change moves the characters our hot keys mean; re-resolve
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { _ in
                Task { @MainActor in MarkupKeys.shared.relayout() }
            }
    }

    /// the two sets register and unregister independently — command keys with
    /// the toolbar, tool keys while a Freeze Frame or an armed Markup Tool is up
    func sync(commands: Bool, tools: Bool) {
        if commands != commandsRegistered { commands ? registerCommands() : unregisterCommands() }
        if tools != toolsRegistered { tools ? registerTools() : unregisterTools() }
    }

    /// the key code that types `character` with ⌘ held in the current
    /// keyboard layout, or nil — ⌘ alone, since ⇧ would turn `[` into `{` —
    /// Carbon hot keys match key codes,
    /// which are physical positions (Z sits where US has Y on German QWERTZ),
    /// and layouts with a Command-specific map ("Dvorak - QWERTY ⌘") move the
    /// shortcut's key
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

    private func installHandler() {
        guard !handlerInstalled else { return }
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

    private func registerCommands() {
        installHandler()
        var failed: [String] = []
        for (i, k) in Self.keys.enumerated() {
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(UInt32(Self.keyCode(typing: k.character) ?? k.fallback), UInt32(k.modifiers),
                                          EventHotKeyID(signature: Self.signature, id: UInt32(i)),
                                          GetApplicationEventTarget(), 0, &ref)
            if let ref { commandRefs.append(ref) }
            if err != noErr { failed.append("\(i) err=\(err)") }
        }
        commandsRegistered = true
        AppLog.line(failed.isEmpty ? "markup keys registered"
                    : "markup keys: \(failed.count) of \(Self.keys.count) failed (\(failed.joined(separator: ", ")))")
    }

    private func unregisterCommands() {
        for r in commandRefs { UnregisterEventHotKey(r) }
        commandRefs = []
        commandsRegistered = false
        AppLog.line("markup keys unregistered")
    }

    /// the Markup Tool Keys, as a local keyDown monitor. Carbon can't carry
    /// them: in the App Sandbox, RegisterEventHotKey refuses a key that types
    /// a character with no modifier or ⇧ alone (eventInternalErr, -9868). A
    /// local monitor sees only keys sent to wadjet, which is active with a
    /// Markup or Freeze Frame panel key whenever the letters are on, so other
    /// apps keep their typing. The current layout decides the letter.
    private func registerTools() {
        if toolMonitor == nil {
            toolMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                MarkupKeys.shared.pressToolKey(e) ? nil : e
            }
        }
        toolsRegistered = true
        AppLog.line("markup tool keys on")
    }

    private func unregisterTools() {
        if let m = toolMonitor { NSEvent.removeMonitor(m) }
        toolMonitor = nil
        toolsRegistered = false
        AppLog.line("markup tool keys off")
    }

    /// true when `e` pressed a Markup Tool Key and armed it; text fields and
    /// the in-place Text editor type the letter instead, and an Editor
    /// window's own keyDown arms its own Markup
    private func pressToolKey(_ e: NSEvent) -> Bool {
        let modified = !e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        guard let key = MarkupToolKey.key(pressed: e.charactersIgnoringModifiers, modified: modified),
              MarkupController.shared.editing == nil,
              !(e.window?.firstResponder is NSText),
              e.window?.windowController?.document == nil else { return false }
        MarkupController.shared.press(key)
        return true
    }

    /// the keyboard layout changed: re-resolve the command keys (the tool
    /// keys read each event's characters, so they follow on their own)
    private func relayout() {
        if commandsRegistered { unregisterCommands(); registerCommands() }
    }

    fileprivate func fire(_ id: Int) {
        guard Self.keys.indices.contains(id) else { return }
        Self.keys[id].action()
    }
}
