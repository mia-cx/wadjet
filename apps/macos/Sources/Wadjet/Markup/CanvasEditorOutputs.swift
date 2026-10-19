import AppKit
import UniformTypeIdentifiers
import WadjetKit

/// The Editor's image outputs: Copy, Export, Share, and Run Workflow all act on
/// `current` — the Canvas plus its live Markup stack — as nil-targeted document
/// actions.
extension CanvasEditorDocument {
    /// The display name as a file name — store Canvases are titled like
    /// "Screenshot Oct 19, 2026 at 10:00 AM", which the filesystem can't take.
    var exportBaseName: String {
        (displayName ?? "Screenshot")
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: ".")
    }

    @IBAction func copy(_ sender: Any?) {
        // link the package only while it matches what's copied — unsaved
        // edits paste as a flat image rather than a link to an older revision
        do { try CanvasClipboard.copy(current, link: isDocumentEdited ? nil : fileURL) }
        catch { presentError(error) }
    }

    @IBAction func exportImage(_ sender: Any?) {
        guard let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.prompt = "Export"
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = exportBaseName
        if let image = sourceImage {
            panel.directoryURL = image.deletingLastPathComponent()
            panel.nameFieldStringValue = image.lastPathComponent
        }
        let picker = ExportFormatPicker(panel: panel,
            type: CanvasImageCodec.exportType(source: sourceImage, hdr: current.showsHDR))
        panel.accessoryView = picker.view
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let image = try self.current.flatten(scale: self.current.outputScale)
                let data = try CanvasImageCodec.export(image, as: picker.type)
                try data.write(to: url) // non-atomic: the sandbox grants only this file
            } catch { self.presentError(error) }
        }
    }

    @IBAction func shareImage(_ sender: Any?) {
        guard let view = windowControllers.first?.window?.contentView else { return }
        do {
            let picker = NSSharingServicePicker(items: [try sharedImageURL()])
            // the hosting view is flipped: its top edge is minY
            let top = view.isFlipped ? view.bounds.minY + 8 : view.bounds.maxY - 8
            let rect = NSRect(x: view.bounds.maxX - 8, y: top, width: 1, height: 1)
            picker.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        } catch { presentError(error) }
    }

    /// the flattened image in a fresh temp folder — what the Share item and
    /// menu hand to NSSharingServicePicker
    func sharedImageURL() throws -> URL {
        let flat = try current.flatImage()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Share").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "\(exportBaseName).\(flat.type.preferredFilenameExtension!)")
        try flat.data.write(to: url)
        return url
    }

    /// Run Workflow submenu item — files the edited Canvas as a new Screenshot
    /// (its own History entry and package) and runs it through the named Workflow.
    @objc func runWorkflow(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        do {
            let crop = current.crop
            try AppDelegate.shared?.writeScreenshot(current, scale: current.outputScale,
                capturedAt: Date(), clear: false,
                label: "Screenshot \(Int(crop.width))×\(Int(crop.height))", workflow: name)
            AppLog.line("editor: ran workflow \(name)")
        } catch { presentError(error) }
    }
}

/// the Export sheet's Format popup — keeps allowedContentTypes and the name's
/// extension in step with the chosen UTType. The sheet's completion retains it.
@MainActor private final class ExportFormatPicker: NSObject {
    private(set) var type: UTType = .png
    let view: NSView
    private weak var panel: NSSavePanel?

    init(panel: NSSavePanel, type initial: UTType) {
        self.panel = panel
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 90, height: 26), pullsDown: false)
        popup.addItems(withTitles: CanvasImageCodec.exportTypes.map { $0.preferredFilenameExtension!.uppercased() })
        view = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        super.init()
        popup.target = self
        popup.action = #selector(changed(_:))
        popup.selectItem(at: CanvasImageCodec.exportTypes.firstIndex(of: initial) ?? 0)
        changed(popup)
    }

    @objc private func changed(_ popup: NSPopUpButton) {
        type = CanvasImageCodec.exportTypes[popup.indexOfSelectedItem]
        guard let panel else { return }
        panel.allowedContentTypes = [type]
        // a stale image extension the new format can't write blocks it from
        // being appended; a non-image tail like "… at 10.00 AM" is never cut
        let ext = (panel.nameFieldStringValue as NSString).pathExtension
        if let t = UTType(filenameExtension: ext), t.conforms(to: .image), !t.conforms(to: type) {
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension
        }
    }
}

/// the File menu's Run Workflow submenu — rebuilt on open so config edits land
@MainActor final class EditorWorkflowMenu: NSObject, NSMenuDelegate {
    static let shared = EditorWorkflowMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let workflows = AppState.shared.config.value.workflows.filter { $0.takes == .screenshot }
        guard !workflows.isEmpty else {
            menu.addItem(NSMenuItem(title: "No Screenshot Workflows", action: nil, keyEquivalent: ""))
            return
        }
        for workflow in workflows {
            let item = NSMenuItem(title: workflow.name,
                action: #selector(CanvasEditorDocument.runWorkflow(_:)), keyEquivalent: "")
            item.representedObject = workflow.name
            menu.addItem(item)
        }
    }
}

/// a Share button in the Editor's title bar, offering the same flattened image
extension CanvasEditorWindowController: NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate {
    private static let shareItemID = NSToolbarItem.Identifier("share")

    func installToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "CanvasEditor")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .flexibleSpace: return NSToolbarItem(itemIdentifier: .flexibleSpace)
        case Self.shareItemID:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.delegate = self
            return item
        default: return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.shareItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func items(for picker: NSSharingServicePickerToolbarItem) -> [Any] {
        guard let doc = document as? CanvasEditorDocument,
              let url = try? doc.sharedImageURL() else { return [] }
        return [url]
    }
}
