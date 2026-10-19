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
public struct CanvasWindowLayer {
    public var frame: CGRect
    public var zOrder: Int
    public var imageFileName: String
    public var image: CGImage

    public init(frame: CGRect, zOrder: Int, imageFileName: String, image: CGImage) {
        self.frame = frame
        self.zOrder = zOrder
        self.imageFileName = imageFileName
        self.image = image
    }
}

/// A reference only: opening a Canvas never resolves links or security-scoped bookmarks.
public struct CanvasLink: Codable, Equatable, Sendable {
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
/// `public.composite-content` conformance in its document type declaration.
public struct CanvasDocument {
    public static let contentType = UTType(exportedAs: "cx.mia.wadjet.canvas", conformingTo: .package)
    public static let version = 1

    public var layout: [CanvasDisplay]
    public var crop: CGRect
    public var cornerRadius: CGFloat
    public var layerStack: LayerStack
    public var displayImages: [UInt32: CGImage]
    public var windowLayers: [CanvasWindowLayer]
    /// Keys are package filenames such as `detail.wadjet`, stored beneath `embedded/`.
    public var embeddedCanvases: [String: CanvasDocument]
    public var linkedCanvases: [CanvasLink]

    // Reuse unedited HEIC bytes on save: repeated Editor saves must not accumulate loss.
    private var originalImages: [String: (image: CGImage, data: Data)] = [:]

    public init(layout: [CanvasDisplay], crop: CGRect, cornerRadius: CGFloat = 0,
                layerStack: LayerStack = LayerStack(), displayImages: [UInt32: CGImage],
                windowLayers: [CanvasWindowLayer] = [], embeddedCanvases: [String: CanvasDocument] = [:],
                linkedCanvases: [CanvasLink] = []) {
        self.layout = layout
        self.crop = crop
        self.cornerRadius = cornerRadius
        self.layerStack = layerStack
        self.displayImages = displayImages
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
        try validateMetadata(windowNames: manifest.windowLayers.map(\.imageFileName))
        for display in layout {
            displayImages[display.id] = try readImage(display.imageFileName, in: fileWrapper)
        }
        for window in manifest.windowLayers {
            guard Self.validRect(window.frame) else { throw CanvasDocumentError.invalidGeometry }
            windowLayers.append(CanvasWindowLayer(frame: window.frame, zOrder: window.zOrder,
                imageFileName: window.imageFileName, image: try readImage(window.imageFileName, in: fileWrapper)))
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
    public func fileWrapper() throws -> FileWrapper {
        try validateMetadata(windowNames: windowLayers.map(\.imageFileName))
        var files: [String: FileWrapper] = [:]
        for display in layout {
            guard let image = displayImages[display.id] else {
                throw CanvasDocumentError.invalidPackage(display.imageFileName)
            }
            files[display.imageFileName] = try imageWrapper(image, name: display.imageFileName)
        }
        for window in windowLayers {
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
        let manifest = Manifest(version: Self.version, layout: layout, crop: crop, cornerRadius: cornerRadius,
            windowLayers: windowLayers.map { WindowMetadata(frame: $0.frame, zOrder: $0.zOrder, imageFileName: $0.imageFileName) },
            embeddedCanvases: embedded.keys.sorted().map { "embedded/\($0)" }, linkedCanvases: linkedCanvases)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        files["canvas.json"] = FileWrapper(regularFileWithContents: try encoder.encode(manifest))
        files["annotations.json"] = FileWrapper(regularFileWithContents: try layerStack.json())
        let thumbnailScale = min(1, 256 / max(crop.width, crop.height))
        let thumbnail = try flatten(scale: thumbnailScale)
        files["thumbnail.png"] = FileWrapper(regularFileWithContents: try CanvasImageCodec.png(thumbnail))
        return FileWrapper(directoryWithFileWrappers: files)
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

    private struct Manifest: Codable {
        var version: Int
        var layout: [CanvasDisplay]
        var crop: CGRect
        var cornerRadius: CGFloat
        var windowLayers: [WindowMetadata]
        var embeddedCanvases: [String]
        var linkedCanvases: [CanvasLink]
    }

    private struct WindowMetadata: Codable {
        var frame: CGRect
        var zOrder: Int
        var imageFileName: String
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
