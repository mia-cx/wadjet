import CoreGraphics
import Foundation
import UniformTypeIdentifiers

extension CanvasDocument {
    /// The pixel scale a flattened crop should render at: the largest backing
    /// scale among displays the crop touches, then any display's, then 1.
    public var outputScale: CGFloat {
        let scales = layout.filter { $0.frame.intersects(crop) }.map(\.scaleFactor)
        return scales.max() ?? layout.map(\.scaleFactor).max() ?? 1
    }

    /// Whether the crop's captured sources carry extended-range pixels. flatten
    /// always uses an extended space, including for SDR, so the sources decide
    /// whether an export needs HEIC or keeps the SDR PNG behaviour.
    public var showsHDR: Bool {
        let sources = layout.filter { $0.frame.intersects(crop) }.compactMap { displayImages[$0.id] }
            + windowLayers.map(\.image)
        return sources.contains {
            $0.colorSpace?.name == CGColorSpace.extendedSRGB || $0.colorSpace?.name == CGColorSpace.extendedLinearSRGB
                || max($0.contentHeadroom, $0.calculatedContentHeadroom) > 1
        }
    }

    /// The flattened crop encoded for output: HEIC when `showsHDR`, else PNG.
    public func flatImage(scale: CGFloat? = nil) throws -> (data: Data, type: UTType) {
        let image = try flatten(scale: scale ?? outputScale)
        if showsHDR { return (try CanvasImageCodec.heic(image), .heic) }
        return (try CanvasImageCodec.png(image), .png)
    }
}

extension CanvasStore {
    /// Files a Canvas as a new Screenshot under a new ID: the flattened image
    /// in `files`, the editable package in the store, both under one base name
    /// that is also free in `pairedWith` (the folder Save file copies the image
    /// to), so the Canvas and its saved image pair up. The Editor's Run Workflow
    /// uses it so the new History entry gets its own Canvas.
    @discardableResult
    public func addScreenshot(_ canvas: CanvasDocument, files: CaptureFiles, scale: CGFloat? = nil,
                              createdAt: Date, pairedWith: [URL] = []) throws -> (id: UUID, file: URL, package: URL) {
        let flat = try canvas.flatImage(scale: scale)
        let taken = CaptureName.takenBaseNames(in: [directory, files.directory] + pairedWith)
        let name = CaptureName.unique(CaptureName.base(for: createdAt), isTaken: taken.contains)
        let file = try files.newFile(ext: flat.type.preferredFilenameExtension!, name: name)
        try flat.data.write(to: file, options: .atomic)
        let id = UUID()
        let package = try add(canvas, for: id, createdAt: createdAt, name: name)
        return (id, file, package)
    }
}

extension HistoryEntry {
    /// The History menu's thumbnail: the Canvas package's while it exists, since
    /// Editor saves re-render it; otherwise the entry's file, an earlier Workflow
    /// output whose bytes and links stay untouched.
    public func thumbnailFile(in store: CanvasStore) -> URL? {
        if let package = try? store.url(for: id) {
            let thumbnail = package.appendingPathComponent("thumbnail.png")
            if FileManager.default.fileExists(atPath: thumbnail.path) { return thumbnail }
        }
        return existingFile
    }
}
