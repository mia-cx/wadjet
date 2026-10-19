import AppKit
import SwiftUI
import WadjetKit

extension AppDelegate {
    /// The Editor's menus in the .regular main menu: File and View get their
    /// own menus after the app menu and Edit; Window gains Colours. Every item
    /// is nil-targeted (document and responder-chain actions), so they enable
    /// only while an Editor window is key or main.
    func installEditorMenus(into main: NSMenu) {
        func mi(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: key)
        }
        let file = NSMenuItem()
        file.submenu = NSMenu(title: "File")
        file.submenu!.addItem(mi("Save", #selector(NSDocument.save(_:)), "s"))
        file.submenu!.addItem(mi("Duplicate", #selector(NSDocument.duplicate(_:)), "S"))
        file.submenu!.addItem(mi("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))

        let view = NSMenuItem()
        view.submenu = NSMenu(title: "View")
        view.submenu!.addItem(mi("Zoom In", #selector(CanvasEditorWindowController.zoomIn(_:)), "+"))
        // ⌘= reaches Zoom In too, though the item never shows
        let eq = mi("Zoom In", #selector(CanvasEditorWindowController.zoomIn(_:)), "=")
        eq.isAlternate = true
        eq.allowsKeyEquivalentWhenHidden = true
        view.submenu!.addItem(eq)
        view.submenu!.addItem(mi("Zoom Out", #selector(CanvasEditorWindowController.zoomOut(_:)), "-"))
        view.submenu!.addItem(mi("Actual Size", #selector(CanvasEditorWindowController.zoomImageToActualSize(_:)), "0"))
        view.submenu!.addItem(mi("Zoom to Fit", #selector(CanvasEditorWindowController.zoomToFit(_:)), "9"))

        main.insertItem(file, at: 1)
        main.insertItem(view, at: 3) // after the app menu, File, and Edit

        if let window = main.items.last {
            window.submenu?.addItem(.separator())
            let colours = NSMenuItem(title: "Colours", action: #selector(ColoursPanel.toggleColours(_:)),
                                     keyEquivalent: "")
            colours.target = ColoursPanel.shared
            window.submenu?.addItem(colours)
        }
    }
}

/// The app-wide floating Colours panel: the main Editor's armed Tool's style
/// controls. Shown while the Window menu's Colours item is checked and an
/// Editor is main; its close button unchecks the item.
@MainActor
final class ColoursPanel: NSObject, NSWindowDelegate {
    static let shared = ColoursPanel()
    /// the Window menu item's checkmark; the panel's close button clears it
    private(set) var wanted = false
    private var panel: NSPanel?

    @objc func toggleColours(_ sender: Any?) {
        wanted.toggle()
        sync()
    }

    /// the checkmark shows the want; the item's only useful with an Editor up
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.state = wanted ? .on : .off
        return EditorFocus.shared.markup != nil
    }

    /// called on every Editor focus change — the panel follows both the want
    /// and whether an Editor is main
    func sync() {
        if wanted, EditorFocus.shared.markup != nil {
            if panel == nil { makePanel() }
            panel?.orderFront(nil)
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() {
        let hosting = NSHostingController(rootView: ColoursPanelContent())
        hosting.sizingOptions = .preferredContentSize
        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        p.title = "Colours"
        p.isFloatingPanel = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = true
        p.appearance = NSAppearance(named: .darkAqua)
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.setFrameAutosaveName("EditorColours")
        panel = p
    }

    nonisolated func windowWillClose(_ n: Notification) {
        Task { @MainActor in self.wanted = false }
    }
}

/// the armed Tool's style controls — Select's when it's nil, Censor, or Clear
private struct ColoursPanelContent: View {
    var tool: Tool {
        guard let t = EditorFocus.shared.markup?.armed,
              t != .censor, t != .clearAnnotations else { return .select }
        return t
    }
    var body: some View {
        MarkupStyleControls(tool: tool, ctrl: AppDelegate.shared!.overlayCtrl)
            .padding(6)
            .frame(width: 280)
    }
}
