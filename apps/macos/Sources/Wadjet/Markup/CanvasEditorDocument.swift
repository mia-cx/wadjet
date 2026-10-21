import AppKit
import WadjetKit

/// The main Editor window's Markup, while one is up — the Tool menus and
/// styles act on it instead of the screen's
@MainActor @Observable
final class EditorFocus {
    static let shared = EditorFocus()
    var markup: MarkupController?
}

extension MarkupController {
    /// the Markup the Tool menus and styles act on: the screen's while its
    /// toolbar is up, else the main Editor window's
    static var active: MarkupController {
        AppState.shared.toolbarOpen ? .shared : EditorFocus.shared.markup ?? .shared
    }
}

/// The Editor's document: one `.wadjet` Canvas package, edited through the
/// AppKit document architecture (the app is .accessory — no SwiftUI DocumentGroup).
/// Crop, corner radius, and Annotations are all undoable.
@objc(CanvasEditorDocument)
final class CanvasEditorDocument: NSDocument {
    /// a placeholder until `read` fills it — documents always open from a package
    private(set) var canvas = CanvasDocument(layout: [], crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                                             displayImages: [:])
    private var markupCached: MarkupController?
    /// the plain image this untitled Canvas came from; Save never writes it —
    /// ⌘S writes `<name>.wadjet` beside it, and Export starts there
    private(set) var sourceImage: URL?
    /// holds the sandbox's related-item access to the sibling .wadjet for later autosaves
    var siblingPresenter: NSFilePresenter?
    /// the window asks to rebuild after a Revert — set by its controller
    var onReload: (() -> Void)?

    override class var autosavesInPlace: Bool { true }
    /// the Save panel never offers an image format now that public.image is an Editor type
    override class var writableTypes: [String] { [CanvasDocument.contentType.identifier] }

    /// an opened image becomes the Canvas — the document stays untitled
    func load(image url: URL) throws {
        canvas = try CanvasDocument(image: Data(contentsOf: url))
        sourceImage = url
    }

    override func close() {
        if let siblingPresenter { NSFileCoordinator.removeFilePresenter(siblingPresenter) }
        siblingPresenter = nil
        super.close()
    }

    /// the Canvas's Markup: edits its own stack, undo lands in the document's
    /// UndoManager, and Select is armed from the start
    var markup: MarkupController {
        if let markupCached { return markupCached }
        let m = MarkupController(editing: canvas.layerStack)
        m.windowLayers = Dictionary(canvas.windowLayers.compactMap { l in l.id.map { ($0, l) } },
                                    uniquingKeysWith: { a, _ in a })
        m.undoManager = undoManager
        m.document = self
        m.snapPixelSources = { [weak self] in
            guard let self else { return [] }
            let canvas = current // the live stack: window Annotations decide each backdrop
            return canvas.layout.map { display in
                MarkupPixelEdges(bounds: display.frame) {
                    do { return try canvas.snappingImage(for: display) }
                    catch {
                        AppLog.line("markup: pixel snapping backdrop failed: \(error.localizedDescription)")
                        return nil
                    }
                }
            }
        }
        seedAssets(into: m)
        m.arm(.select)
        markupCached = m
        return m
    }

    /// the Canvas plus the live Markup stack and its image assets — what Save,
    /// Copy, Export, and Share all act on. `.image` payloads and `.canvas`
    /// snapshots persist only while the stack references them; linked Canvases
    /// go into `linkedDocuments` so `fileWrapper` writes their snapshots,
    /// `linkedCanvases` keeps the package's own links plus every Annotation's,
    /// and `embeddedCanvases` the Canvases the stack's `.embedded` Annotations name.
    var current: CanvasDocument {
        var canvas = canvas
        guard let markupCached else { return canvas }
        canvas.layerStack = markupCached.stack
        var used = Set<UUID>()
        var links = canvas.linkedCanvases
        var embedded: [String: CanvasDocument] = [:]
        for a in canvas.layerStack.annotations {
            switch a.kind {
            case let .image(asset, _): used.insert(asset)
            case let .canvas(.linked(link), _):
                used.insert(a.id)
                if !links.contains(link) { links.append(link) }
            case let .canvas(.embedded(name), _):
                if let doc = markupCached.assets.embedded[name] { embedded[name] = doc }
            default: break
            }
        }
        canvas.images = markupCached.assets.images.filter { used.contains($0.key) }
        canvas.linkedDocuments = markupCached.assets.canvases
        canvas.linkedCanvases = links
        canvas.embeddedCanvases = embedded
        return canvas
    }

    /// the package's image payloads and the linked Canvases its `linkedCanvases`
    /// lists, plus its embedded full sources, so saved copies can still recrop
    /// after History expiry.
    private func seedAssets(into m: MarkupController) {
        m.assets.removeAll() // the reload's payload replaces everything, cached flattens too
        m.assets.images = canvas.images
        m.assets.embedded = canvas.embeddedCanvases
        m.assets.canvases = canvas.linkedDocuments
        for link in canvas.linkedCanvases where m.assets.canvases[link.url] == nil
            && FileManager.default.fileExists(atPath: link.url.path) {
            m.assets.canvases[link.url] = try? CanvasDocument.read(from: link.url)
        }
    }

    // read/write run off the main actor in the macOS 26 SDK; AppKit still calls
    // them on the main thread, so the Canvas and Markup stay MainActor state
    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let wrapper = UnsafeSendable(value: fileWrapper)
        try MainActor.assumeIsolated {
            canvas = try CanvasDocument(fileWrapper: wrapper.value)
            if let markupCached {
                markupCached.windowLayers = Dictionary(
                    canvas.windowLayers.compactMap { l in l.id.map { ($0, l) } },
                    uniquingKeysWith: { a, _ in a })
                markupCached.load(canvas.layerStack)
                seedAssets(into: markupCached)
                onReload?()
            }
        }
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        // FileWrapper can't cross the isolation boundary even synchronously
        try MainActor.assumeIsolated {
            var writing = current
            if isStorePackage { return UnsafeSendable(value: try writing.fileWrapper()) }
            let wrapper = try writing.archiveLinkedCanvases()
            // Cache archived sources without reloading Markup or its undo stack.
            // A later autosave must not need the History files archived here.
            canvas = writing
            markupCached?.assets.canvases.merge(writing.linkedDocuments) { _, archived in archived }
            markupCached?.assets.embedded.merge(writing.embeddedCanvases) { _, archived in archived }
            return UnsafeSendable(value: wrapper)
        }.value
    }

    /// an undoable crop/radius edit — one undo step per gesture or slider drag
    func setCrop(_ crop: CGRect, cornerRadius radius: CGFloat, undoingTo old: (CGRect, CGFloat)) {
        canvas.crop = crop
        canvas.cornerRadius = radius
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.setCrop(old.0, cornerRadius: old.1, undoingTo: (crop, radius))
            }
        }
        onReload?()
    }

    /// called after every successful save — tell Markup the text session's
    /// dirty mark went with it so later keystrokes dirty the document again
    override func updateChangeCount(withToken changeToken: Any, for saveOperation: SaveOperationType) {
        super.updateChangeCount(withToken: changeToken, for: saveOperation)
        markupCached?.textSessionSaved()
    }

    /// History's packages in original/ — other Canvases link to them by path,
    /// so renaming or moving them is refused. A user's own Canvas saved into
    /// original/ isn't one of them and saves like any other permanent file.
    private var isStorePackage: Bool {
        guard let url = fileURL, let store = AppDelegate.shared?.canvasStore else { return false }
        return store.owns(url)
    }

    override func move(to url: URL, completionHandler: (((any Error)?) -> Void)? = nil) {
        if isStorePackage {
            completionHandler?(CocoaError(.fileWriteNoPermission))
            return
        }
        super.move(to: url, completionHandler: completionHandler)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // Copy is the Canvas's only while no Annotation is selected — a selected
        // Annotation's Copy belongs to its view
        if item.action == #selector(CanvasEditorDocument.copy(_:)) {
            return markupCached?.selection.isEmpty ?? true
        }
        if isStorePackage,
           item.action == #selector(NSDocument.rename(_:))
            || item.action == #selector(NSDocument.move(_:)) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    /// an unsaved edit of an image is titled by that image
    override var displayName: String! {
        get {
            if fileURL == nil, let sourceImage {
                return FileManager.default.displayName(atPath: sourceImage.path)
            }
            return super.displayName
        }
        set { super.displayName = newValue }
    }

    override func makeWindowControllers() {
        let wc = CanvasEditorWindowController()
        addWindowController(wc) // first: setUp's `guard let doc` needs it attached
        wc.setUp()
    }

    /// a menu-bar app opening a document window joins the Dock for it
    override func showWindows() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        super.showWindows()
    }
}

/// carries a non-Sendable value through `MainActor.assumeIsolated`, which is
/// synchronous — nothing really crosses
private struct UnsafeSendable<T>: @unchecked Sendable { let value: T }

extension AppDelegate {
    /// opens a Canvas package in the Editor — a toast or History click
    func openCanvas(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            if let error {
                AppLog.line("editor: open \(url.lastPathComponent) failed: \(error.localizedDescription)")
                NSApp.presentError(error)
            } else if let doc {
                AppLog.line("editor: opened \(doc.displayName ?? url.lastPathComponent)")
            }
        }
    }

    /// .regular while a Settings or Editor window is up, .accessory otherwise.
    /// `closing` is the window about to go — willClose runs while it's still visible.
    func syncActivationPolicy(closing: NSWindow? = nil) {
        let up = NSApp.windows.contains { w in
            w !== closing && (w.isVisible || w.isMiniaturized)
                && (w === settingsWindow || w.windowController?.document is CanvasEditorDocument)
        }
        NSApp.setActivationPolicy(up ? .regular : .accessory)
    }
}
