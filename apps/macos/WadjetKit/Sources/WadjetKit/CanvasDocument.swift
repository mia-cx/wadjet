import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// One uncropped display, positioned in AppKit global screen points.
public struct CanvasDisplay: Codable, Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var scaleFactor: CGFloat
    public var imageFileName: String

    public init(id: UInt32, frame: CGRect, scaleFactor: CGFloat, imageFileName: String? = nil) {
        self.id = id
        self.frame = frame
        self.scaleFactor = scaleFactor
        self.imageFileName = imageFileName ?? "display-\(id).heic"
    }
}

/// A captured window above the flat displays. Larger z-orders draw in front.
/// A nil `id` is a backdrop layer (old Canvases and the standalone Capture
/// Window image), drawn beneath every Annotation by zOrder as before; a
/// non-nil `id` draws only through the `.window` Annotation naming it.
public struct CanvasWindowLayer {
    public var frame: CGRect
    public var zOrder: Int
    public var imageFileName: String
    public var image: CGImage
    /// A standalone window Screenshot replaces the desktop beneath its frame,
    /// preserving window alpha while retaining the displays for recropping.
    public var isolatesBackground: Bool
    public var id: UUID?
    public var app: String?
    public var title: String?

    public init(frame: CGRect, zOrder: Int, imageFileName: String, image: CGImage, isolatesBackground: Bool = false,
                id: UUID? = nil, app: String? = nil, title: String? = nil) {
        self.frame = frame
        self.zOrder = zOrder
        self.imageFileName = imageFileName
        self.image = image
        self.isolatesBackground = isolatesBackground
        self.id = id
        self.app = app
        self.title = title
    }
}

/// A reference only: opening a Canvas never resolves links or security-scoped bookmarks.
public struct CanvasLink: Codable, Hashable, Sendable {
    public var url: URL
    public var bookmarkData: Data?

    public init(url: URL, bookmarkData: Data? = nil) {
        self.url = url
        self.bookmarkData = bookmarkData
    }
}

/// Editable Screenshot contents, independent of screen capture and SwiftUI.
/// All geometry is in AppKit global points, including Annotations outside the crop.
/// The app must export this identifier with `com.apple.package` and
/// `public.composite-content` conformance in its exported type declaration.
public struct CanvasDocument {
    public static let contentType = UTType(exportedAs: "cx.mia.wadjet.canvas", conformingTo: .package)
    public static let version = 1

    public var layout: [CanvasDisplay]
    public var crop: CGRect
    public var cornerRadius: CGFloat
    public var layerStack: LayerStack
    public var displayImages: [UInt32: CGImage]
    /// the assets `.image` Annotations name plus each `.canvas` Annotation's
    /// persisted snapshot of its linked Canvas — stored under `images/`, keyed
    /// by the asset id or the Annotation's own id
    public var images: [UUID: CGImage]
    public var windowLayers: [CanvasWindowLayer]
    /// Keys are package filenames such as `detail.wadjet`, stored beneath `embedded/`.
    public var embeddedCanvases: [String: CanvasDocument]
    public var linkedCanvases: [CanvasLink]
    /// linked Canvases the caller already opened, keyed by link URL, so flatten
    /// draws `.canvas` Annotations live; never persisted — a resolvable link's
    /// content is snapshotted under `images/<annotation-id>` at write time
    /// instead, so a reopened package still renders
    public var linkedDocuments: [URL: CanvasDocument] = [:]
    // Travels with Editor saves so History retention never restarts after an edit.
    var storeMetadata: CanvasStoreMetadata?

    // Reuse unedited HEIC bytes on save: repeated Editor saves must not accumulate loss.
    private var originalImages: [String: (image: CGImage, data: Data)] = [:]

    public init(layout: [CanvasDisplay], crop: CGRect, cornerRadius: CGFloat = 0,
                layerStack: LayerStack = LayerStack(), displayImages: [UInt32: CGImage],
                images: [UUID: CGImage] = [:],
                windowLayers: [CanvasWindowLayer] = [], embeddedCanvases: [String: CanvasDocument] = [:],
                linkedCanvases: [CanvasLink] = []) {
        self.layout = layout
        self.crop = crop
        self.cornerRadius = cornerRadius
        self.layerStack = layerStack
        self.displayImages = displayImages
        self.images = images
        self.windowLayers = windowLayers
        self.embeddedCanvases = embeddedCanvases
        self.linkedCanvases = linkedCanvases
    }

    /// Opens a package without following any linked Canvas or symbolic link inside it.
    public static func read(from url: URL) throws -> CanvasDocument {
        try CanvasDocument(fileWrapper: FileWrapper(url: url, options: .immediate))
    }

    /// Atomically replaces a package; suitable for a future ReferenceFileDocument adapter.
    public func write(to url: URL) throws {
        try fileWrapper().write(to: url, options: .atomic, originalContentsURL: nil)
    }

    /// Decodes the same package wrapper SwiftUI supplies to a document's read method.
    public init(fileWrapper: FileWrapper) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Self.data("canvas.json", in: fileWrapper))
        guard manifest.version == Self.version else { throw CanvasDocumentError.unsupportedVersion(manifest.version) }
        self.init(layout: manifest.layout, crop: manifest.crop, cornerRadius: manifest.cornerRadius,
                  layerStack: try LayerStack(json: Self.data("annotations.json", in: fileWrapper)),
                  displayImages: [:], linkedCanvases: manifest.linkedCanvases)
        storeMetadata = manifest.store
        try validateMetadata(windowNames: manifest.windowLayers.map(\.imageFileName))
        for display in layout {
            displayImages[display.id] = try readImage(display.imageFileName, in: fileWrapper)
        }
        for window in manifest.windowLayers {
            guard Self.validRect(window.frame) else { throw CanvasDocumentError.invalidGeometry }
            windowLayers.append(CanvasWindowLayer(frame: window.frame, zOrder: window.zOrder,
                imageFileName: window.imageFileName, image: try readImage(window.imageFileName, in: fileWrapper),
                isolatesBackground: window.isolatesBackground ?? false,
                id: window.id, app: window.app, title: window.title))
        }
        try validateWindowLayers()
        // Packages written before assets existed have no images/ directory.
        if let assets = fileWrapper.fileWrappers?["images"] {
            guard assets.isDirectory else { throw CanvasDocumentError.invalidPackage("images") }
            for (name, child) in assets.fileWrappers ?? [:] {
                let ext = name.hasSuffix(".heic") ? 5 : name.hasSuffix(".png") ? 4 : 0
                guard ext > 0, let asset = UUID(uuidString: String(name.dropLast(ext))),
                      child.isRegularFile, let data = child.regularFileContents else {
                    throw CanvasDocumentError.invalidPackage("images/\(name)")
                }
                let image = try CanvasImageCodec.decode(data)
                originalImages["images/\(name)"] = (image, data)
                images[asset] = image
            }
        }
        for path in manifest.embeddedCanvases {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "embedded", Self.validName(String(parts[1])),
                  parts[1].hasSuffix(".wadjet"), embeddedCanvases[String(parts[1])] == nil,
                  let wrapper = fileWrapper.fileWrappers?["embedded"]?.fileWrappers?[String(parts[1])] else {
                throw CanvasDocumentError.invalidPackage(path)
            }
            embeddedCanvases[String(parts[1])] = try CanvasDocument(fileWrapper: wrapper)
        }
    }

    /// Builds the complete directory wrapper, including a flattened SDR thumbnail.
    /// An id'd window layer is written only while a `.window` Annotation names
    /// it — deleting the Annotation drops its image from the saved package.
    public func fileWrapper() throws -> FileWrapper {
        try validateWindowLayers()
        let written = writtenWindowLayers
        try validateMetadata(windowNames: written.map(\.imageFileName))
        var files: [String: FileWrapper] = [:]
        for display in layout {
            guard let image = displayImages[display.id] else {
                throw CanvasDocumentError.invalidPackage(display.imageFileName)
            }
            files[display.imageFileName] = try imageWrapper(image, name: display.imageFileName)
        }
        for window in written {
            guard Self.validRect(window.frame) else { throw CanvasDocumentError.invalidGeometry }
            files[window.imageFileName] = try imageWrapper(window.image, name: window.imageFileName)
        }
        var embedded: [String: FileWrapper] = [:]
        for (name, canvas) in embeddedCanvases {
            guard Self.validName(name), name.hasSuffix(".wadjet") else {
                throw CanvasDocumentError.invalidPackage(name)
            }
            embedded[name] = try canvas.fileWrapper()
        }
        files["embedded"] = FileWrapper(directoryWithFileWrappers: embedded)
        // .canvas Annotations persist a snapshot of their linked Canvas at the
        // Annotation's own id, so a reopened package (no linkedDocuments) still
        // renders; an unresolvable link keeps whatever images[annotation.id]
        // the package carried — all merged here without mutating self
        var assets = images
        for a in layerStack.annotations {
            guard case let .canvas(.linked(link), placement) = a.kind,
                  var child = linkedDocuments[link.url] else { continue }
            child.cornerRadius = 0 // the Annotation's own radius rounds it
            let k = max(placement.frame.width / placement.crop.width,
                        placement.frame.height / placement.crop.height)
            assets[a.id] = try child.flatten(crop: placement.crop,
                scale: k * (child.layout.map(\.scaleFactor).max() ?? 1))
        }
        var wrappers: [String: FileWrapper] = [:]
        for (asset, image) in assets.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let hdr = max(image.contentHeadroom, image.calculatedContentHeadroom) > 1
            let name = "\(asset.uuidString).\(hdr ? "heic" : "png")"
            let data: Data
            if let original = originalImages["images/\(name)"], original.image === image {
                data = original.data
            } else {
                data = hdr ? try CanvasImageCodec.heic(image) : try CanvasImageCodec.png(image)
            }
            let file = FileWrapper(regularFileWithContents: data)
            file.preferredFilename = name
            wrappers[name] = file
        }
        files["images"] = FileWrapper(directoryWithFileWrappers: wrappers)
        let manifest = Manifest(version: Self.version, layout: layout, crop: crop, cornerRadius: cornerRadius,
            windowLayers: written.map { WindowMetadata(frame: $0.frame, zOrder: $0.zOrder,
                imageFileName: $0.imageFileName, isolatesBackground: $0.isolatesBackground ? true : nil,
                id: $0.id, app: $0.app, title: $0.title) },
            embeddedCanvases: embedded.keys.sorted().map { "embedded/\($0)" }, linkedCanvases: linkedCanvases,
            store: storeMetadata)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        files["canvas.json"] = FileWrapper(regularFileWithContents: try encoder.encode(manifest))
        files["annotations.json"] = FileWrapper(regularFileWithContents: try layerStack.json())
        let thumbnailScale = min(1, 256 / max(crop.width, crop.height))
        let thumbnail = try flatten(scale: thumbnailScale)
        files["thumbnail.png"] = FileWrapper(regularFileWithContents: try CanvasImageCodec.png(thumbnail, colourSpace: CGColorSpace.sRGB))
        return FileWrapper(directoryWithFileWrappers: files)
    }

    /// the window layers a save writes: every backdrop layer plus each id'd
    /// layer some `.window` Annotation in `layerStack` references
    private var writtenWindowLayers: [CanvasWindowLayer] {
        let referenced = Set(layerStack.annotations.compactMap { a -> UUID? in
            guard case let .window(id, _) = a.kind else { return nil }
            return id
        })
        return windowLayers.filter { $0.id.map(referenced.contains) ?? true }
    }

    /// window layer ids are unique, and every `.window` Annotation names one
    private func validateWindowLayers() throws {
        let ids = windowLayers.compactMap(\.id)
        guard Set(ids).count == ids.count else {
            throw CanvasDocumentError.invalidPackage("duplicate window layer ids")
        }
        let known = Set(ids)
        for case let .window(id, _) in layerStack.annotations.map(\.kind) {
            guard known.contains(id) else {
                throw CanvasDocumentError.invalidPackage("window Annotation \(id) has no layer")
            }
        }
    }

    private mutating func readImage(_ name: String, in wrapper: FileWrapper) throws -> CGImage {
        let data = try Self.data(name, in: wrapper)
        let image = try CanvasImageCodec.decode(data)
        originalImages[name] = (image, data)
        return image
    }

    private func imageWrapper(_ image: CGImage, name: String) throws -> FileWrapper {
        let data: Data
        if let original = originalImages[name], original.image === image {
            data = original.data
        } else {
            data = try CanvasImageCodec.heic(image)
        }
        return FileWrapper(regularFileWithContents: data)
    }

    private func validateMetadata(windowNames: [String]) throws {
        guard Self.validRect(crop), cornerRadius.isFinite, cornerRadius >= 0,
              layout.allSatisfy({ Self.validRect($0.frame) && $0.scaleFactor.isFinite && $0.scaleFactor > 0 }) else {
            throw CanvasDocumentError.invalidGeometry
        }
        let names = layout.map(\.imageFileName) + windowNames
        guard Set(layout.map(\.id)).count == layout.count, Set(names).count == names.count,
              names.allSatisfy({ Self.validName($0) && $0.hasSuffix(".heic") }),
              linkedCanvases.allSatisfy({ $0.url.isFileURL }) else {
            throw CanvasDocumentError.invalidPackage("duplicate display IDs, invalid image filenames, or non-file links")
        }
    }

    private static func data(_ name: String, in wrapper: FileWrapper) throws -> Data {
        guard wrapper.isDirectory, let child = wrapper.fileWrappers?[name], child.isRegularFile,
              let data = child.regularFileContents else { throw CanvasDocumentError.invalidPackage(name) }
        return data
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    static func validRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
    }

    struct Manifest: Codable {
        var version: Int
        var layout: [CanvasDisplay]
        var crop: CGRect
        var cornerRadius: CGFloat
        var windowLayers: [WindowMetadata]
        var embeddedCanvases: [String]
        var linkedCanvases: [CanvasLink]
        var store: CanvasStoreMetadata?
    }

    struct WindowMetadata: Codable {
        var frame: CGRect
        var zOrder: Int
        var imageFileName: String
        var isolatesBackground: Bool?
        // nil fields omit themselves, so manifests written before window
        // layers existed read identically
        var id: UUID?
        var app: String?
        var title: String?
    }
}

/// Package corruption, unsupported formats, and render allocation failures surface to the caller.
public enum CanvasDocumentError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidPackage(String)
    case invalidGeometry
    case imageEncodingFailed
    case imageDecodingFailed
    case renderFailed
}
