import AppKit
import ImageIO
import UniformTypeIdentifiers
import WadjetKit

/// the pixels and Canvases image-kind Annotations draw from — session state kept
/// outside the LayerStack so undo snapshots stay small; one per MarkupController
@MainActor
final class MarkupAssets {
    /// image bytes the `.image` Annotations name (and persisted `.canvas` snapshots)
    var images: [UUID: CGImage] = [:]
    /// pasted Canvases the `.canvas` Annotations link, keyed by link URL
    var canvases: [URL: CanvasDocument] = [:]
    /// Canvases the `.canvas` Annotations embed — Freeze region's frozen pixels
    var embedded: [String: CanvasDocument] = [:]
    /// a nested Canvas flattens once per source — its own edits don't travel
    private var flattened: [NestedCanvas: CanvasPixels] = [:]

    func removeAll() { images = [:]; canvases = [:]; embedded = [:]; flattened = [:] }

    /// the document a `.canvas` Annotation resolves to — the link's opened
    /// package or the embedded one it names
    func document(for nested: NestedCanvas) -> CanvasDocument? {
        switch nested {
        case let .linked(link): canvases[link.url]
        case let .embedded(name): embedded[name]
        }
    }

    /// whether the Annotation's real source is still around to recrop in —
    /// a `.canvas` whose link is gone still displays its persisted snapshot,
    /// but recropping would stretch the whole snapshot into the new crop
    func canRecrop(_ a: Annotation) -> Bool {
        switch a.kind {
        case let .image(asset, _): images[asset] != nil
        case let .canvas(nested, _): document(for: nested) != nil
        case .line, .path, .censor, .shape, .counter, .magnify, .text, .window: false
        }
    }

    /// what the panels draw and recrop within: `.image` → the asset and its
    /// pixel bounds; `.canvas` → the nested Canvas flattened over its layout,
    /// whose union is the recrop's bounds, or the persisted snapshot clamped to
    /// the Annotation's own crop; nil when the payload is missing
    func source(for a: Annotation) -> CanvasPixels? {
        switch a.kind {
        case let .image(asset, _):
            guard let image = images[asset] else { return nil }
            return CanvasPixels(image: image,
                                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        case let .canvas(nested, placement):
            if let f = flattened[nested] { return f }
            if var doc = document(for: nested),
               let union = doc.layout.map(\.frame).reduce(nil, { $0?.union($1) ?? $1 }) {
                doc.cornerRadius = 0 // the Annotation's own radius rounds it
                if let image = try? doc.flatten(crop: union,
                    scale: doc.layout.map(\.scaleFactor).max() ?? 1) {
                    flattened[nested] = CanvasPixels(image: image, bounds: union)
                    return flattened[nested]
                }
            }
            // the persisted snapshot displays too; recrop clamps to the crop — links only
            guard case .linked = nested, let snapshot = images[a.id] else { return nil }
            return CanvasPixels(image: snapshot, bounds: placement.crop)
        case .line, .path, .censor, .shape, .counter, .magnify, .text, .window:
            return nil
        }
    }
}

/// reading the clipboard for Markup: a wadjet Canvas first — its paste stays
/// recroppable — then image files, raw image data, and NSImage's own reading
enum MarkupPasteboard {
    enum Content {
        case canvas(CanvasDocument, CanvasLink)
        case image(CGImage, size: CGSize)
        var label: String { if case .canvas = self { "canvas" } else { "image" } }
    }

    /// a cheap type check — no decoding — for drag acceptance
    static func canRead(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]]) { return true }
        if pb.canReadObject(forClasses: [NSImage.self]) { return true }
        return (pb.types ?? []).contains {
            [.init(CanvasDocument.contentType.identifier), .png, .tiff,
             NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")].contains($0)
        }
    }

    static func read(_ pb: NSPasteboard) -> Content? {
        // wadjet's own copy carries the package and its History URL — a missing
        // or dead link falls through to the flat image the copy also offers
        if let link = link(in: pb),
           let data = pb.data(forType: .init(CanvasDocument.contentType.identifier)),
           let doc = try? CanvasDocument.read(serializedPackage: data) {
            return .canvas(doc, link)
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL] {
            for url in urls {
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let (image, size) = ImportedImage.decode(src) { return .image(image, size: size) }
            }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff,
                     NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")] {
            if let data = pb.data(forType: type),
               let src = CGImageSourceCreateWithData(data as CFData, nil),
               let (image, size) = ImportedImage.decode(src) { return .image(image, size: size) }
        }
        if let ns = NSImage(pasteboard: pb),
           let image = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return .image(image, size: ns.size)
        }
        return nil
    }

    /// the History package URL CanvasClipboard wrote — valid only while it exists
    private static func link(in pb: NSPasteboard) -> CanvasLink? {
        guard let s = pb.string(forType: CanvasClipboard.linkType),
              let url = URL(string: s), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return CanvasLink(url: url)
    }
}
