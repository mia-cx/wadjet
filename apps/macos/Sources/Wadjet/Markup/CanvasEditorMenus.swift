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
        file.submenu!.addItem(.separator())
        file.submenu!.addItem(mi("Export…", #selector(CanvasEditorDocument.exportImage(_:)), "E"))
        file.submenu!.addItem(mi("Share…", #selector(CanvasEditorDocument.shareImage(_:))))
        let workflows = NSMenuItem(title: "Run Workflow", action: nil, keyEquivalent: "")
        workflows.submenu = NSMenu(title: "Run Workflow")
        workflows.submenu!.delegate = EditorWorkflowMenu.shared
        file.submenu!.addItem(workflows)

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
            window.submenu?.addItem(EditorPanel.layers.menuItem("l", modifiers: [.command, .option]))
            window.submenu?.addItem(EditorPanel.colours.menuItem())
        }
    }
}

/// One app-wide floating Editor panel: shown while its Window-menu item is
/// checked and an Editor is main; the close button unchecks it. Colours and
/// Layers share the machinery — only the panel's contents and framing differ.
@MainActor
final class EditorPanel: NSObject, NSWindowDelegate {
    /// the Window menu item's checkmark; the panel's close button clears it
    private(set) var wanted = false
    private var panel: NSPanel?
    private let makePanel: () -> NSPanel

    private init(_ makePanel: @escaping () -> NSPanel) {
        self.makePanel = makePanel
    }

    static let colours = EditorPanel {
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
        p.setFrameAutosaveName("EditorColours")
        return p
    }
    /// the screen's LayersPanel, tamed for document windows: normal level and
    /// space behaviour, hides with the app like the other Editor panels
    static let layers = EditorPanel {
        let p = LayersPanel(content: EditorLayersList())
        p.level = .floating
        p.collectionBehavior = []
        p.hidesOnDeactivate = true
        p.setFrameAutosaveName("EditorLayers")
        return p
    }

    @objc func toggle(_ sender: Any?) {
        wanted.toggle()
        sync()
    }

    /// every Editor focus change syncs both panels
    static func syncAll() {
        colours.sync()
        layers.sync()
    }

    func menuItem(_ key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: panelTitle, action: #selector(toggle(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }
    private var panelTitle: String { self === EditorPanel.layers ? "Layers" : "Colours" }

    /// the checkmark shows the want; the item's only useful with an Editor up
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.state = wanted ? .on : .off
        return EditorFocus.shared.markup != nil
    }

    /// called on every Editor focus change — the panel follows both the want
    /// and whether an Editor is main
    func sync() {
        if wanted, EditorFocus.shared.markup != nil {
            if panel == nil {
                let p = makePanel()
                p.delegate = self
                panel = p
            }
            panel?.orderFront(nil)
        } else {
            panel?.orderOut(nil)
        }
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

/// the focused Editor's Annotations, bound to its controller like the screen's
/// MarkupLayersList is to the shared one
private struct EditorLayersList: View {
    var body: some View {
        if let c = EditorFocus.shared.markup {
            LayersView(annotations: c.stack.annotations,
                       selection: Binding(get: { c.selection }, set: { c.select($0) }),
                       move: c.moveLayer,
                       update: c.update,
                       windowLayers: c.windowLayers)
        }
    }
}
