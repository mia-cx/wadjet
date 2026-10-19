import AppKit
import Carbon

/// Markup's command keys (⌘Z, ⇧⌘Z) as Carbon hot keys, registered while the
/// toolbar is open — the same seam Escape uses — so the apps underneath keep
/// their own undo the rest of the time.
@MainActor
final class MarkupKeys {
    static let shared = MarkupKeys()
    /// 'wmky'; Escape/Measure/Space use 'wdjt' — each handler passes through foreign signatures
    private static let signature = OSType(0x776D6B79)
    /// key code, Carbon modifiers, action — hot key id = row index, so the next slice just appends rows
    private static let keys: [(code: Int, modifiers: Int, action: @MainActor () -> Void)] = [
        (kVK_ANSI_Z, cmdKey, { MarkupController.shared.undo() }),
        (kVK_ANSI_Z, cmdKey | shiftKey, { MarkupController.shared.redo() }),
    ]
    private var refs: [EventHotKeyRef] = []
    private var registered = false
    private var handlerInstalled = false
    private init() {}

    /// register while the toolbar is open, unregister when it closes; no-op when unchanged
    func sync(active: Bool) {
        guard active != registered else { return }
        if active {
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
                let err = RegisterEventHotKey(UInt32(k.code), UInt32(k.modifiers),
                                              EventHotKeyID(signature: Self.signature, id: UInt32(i)),
                                              GetApplicationEventTarget(), 0, &ref)
                if let ref { refs.append(ref) }
                if err != noErr { AppLog.line("markup keys: hot key \(i) err=\(err)") }
            }
            registered = true
            AppLog.line("markup keys registered")
        } else {
            for r in refs { UnregisterEventHotKey(r) }
            refs = []
            registered = false
            AppLog.line("markup keys unregistered")
        }
    }

    fileprivate func fire(_ index: Int) {
        guard Self.keys.indices.contains(index) else { return }
        Self.keys[index].action()
    }
}
