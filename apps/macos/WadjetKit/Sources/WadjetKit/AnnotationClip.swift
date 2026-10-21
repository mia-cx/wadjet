import CoreGraphics
import Foundation

/// Annotations copied with ⌘C together with the pixels and Canvases they
/// draw from, so a paste can rebuild them in any Canvas. It travels on the
/// system pasteboard as a Canvas package of just these Annotations (private
/// to wadjet, so a later launch can paste it) next to a flattened image of
/// them for other apps.
public struct AnnotationClip {
    public var annotations: [Annotation]
    /// `.image` assets by asset id
    public var images: [UUID: CGImage]
    /// opened linked Canvases by link URL — in memory only; the package keeps snapshots
    public var canvases: [URL: CanvasDocument]
    /// embedded Canvases by package filename
    public var embedded: [String: CanvasDocument]
    /// linked Canvases' persisted snapshots, by the copied Annotation's id
    public var snapshots: [UUID: CGImage]
    /// captured windows' pixels, by layer id — another Canvas has no such layer
    public var windowImages: [UUID: CGImage]

    public init(annotations: [Annotation], images: [UUID: CGImage] = [:],
                canvases: [URL: CanvasDocument] = [:], embedded: [String: CanvasDocument] = [:],
                snapshots: [UUID: CGImage] = [:], windowImages: [UUID: CGImage] = [:]) {
        self.annotations = annotations
        self.images = images
        self.canvases = canvases
        self.embedded = embedded
        self.snapshots = snapshots
        self.windowImages = windowImages
    }

    /// the area the copied Annotations paint: their shared box grown by
    /// enough for strokes and line ends to stay inside, never empty
    public var paintedBounds: CGRect {
        let box = AnnotationGroup.bounds(of: annotations)
        guard !box.isNull else { return .null }
        let pad = (annotations.map(\.style.width).max() ?? 0) * 3 + 2
        return box.insetBy(dx: -pad, dy: -pad).integral
    }

    /// a Canvas holding only these Annotations over nothing: what the
    /// private pasteboard type carries and the flattened image draws.
    /// A Window Annotation whose pixels weren't copied can't travel, so it is left out.
    public var document: CanvasDocument {
        let kept = annotations.filter {
            if case let .window(id, _) = $0.kind { windowImages[id] != nil } else { true }
        }
        var assets = images
        for (id, image) in snapshots { assets[id] = image }
        var links: [URL: CanvasLink] = [:]
        var windows: [CanvasWindowLayer] = []
        for a in kept {
            switch a.kind {
            case let .canvas(.linked(link), _): links[link.url] = link
            case let .window(id, frame):
                guard let image = windowImages[id], !windows.contains(where: { $0.id == id }) else { continue }
                windows.append(CanvasWindowLayer(frame: frame, zOrder: windows.count,
                    imageFileName: "window-\(id.uuidString).heic", image: image, id: id))
            default: break
            }
        }
        let bounds = paintedBounds
        var doc = CanvasDocument(layout: [], crop: bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds,
                                 layerStack: LayerStack(kept), displayImages: [:], images: assets,
                                 windowLayers: windows, embeddedCanvases: embedded,
                                 linkedCanvases: links.values.sorted { $0.url.absoluteString < $1.url.absoluteString })
        doc.linkedDocuments = canvases
        return doc
    }

    /// what the system pasteboard gets: the private package and a PNG of the
    /// Annotations alone, transparent around them, at `scale` pixels per point
    public func pasteboardData(scale: CGFloat = 2) throws -> (package: Data, png: Data) {
        let doc = document
        let flat = try doc.flatten(scale: scale)
        return (try doc.serializedPackage(), try CanvasImageCodec.png(flat, colourSpace: CGColorSpace.sRGB))
    }

    /// the clip a package from `pasteboardData` carries
    public init(package data: Data) throws {
        let doc = try CanvasDocument.read(serializedPackage: data)
        let annotations = doc.layerStack.annotations
        let snapshotIDs = Set(annotations.compactMap { a -> UUID? in
            if case .canvas(.linked, _) = a.kind { a.id } else { nil }
        })
        var windowImages: [UUID: CGImage] = [:]
        for w in doc.windowLayers { if let id = w.id { windowImages[id] = w.image } }
        self.init(annotations: annotations,
                  images: doc.images.filter { !snapshotIDs.contains($0.key) },
                  embedded: doc.embeddedCanvases,
                  snapshots: doc.images.filter { snapshotIDs.contains($0.key) },
                  windowImages: windowImages)
    }
}
