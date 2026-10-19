import AppKit
import Foundation
import Testing
import WadjetKit

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}
private func mkFile(_ dir: URL, _ name: String = "a.png") throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent(name)
    try Data("png".utf8).write(to: f)
    return f
}
private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_700_000_000) }

@Test @MainActor func recentReturnsNewestFirstUpToTheLimit() throws {
    let store = try HistoryStore.inMemory()
    for i in 0..<12 {
        try store.record(kind: .screenshot, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), file: nil)
    }
    let recent = try store.recent()
    #expect(recent.count == 10)
    #expect(recent.first!.createdAt > recent.last!.createdAt)
    #expect(recent.first!.createdAt == Date(timeIntervalSince1970: 1_700_000_000 + 11))
}

@Test @MainActor func entryKeepsItsStepErrorsAndFile() throws {
    let store = try HistoryStore.inMemory()
    let file = try mkFile(tempDir())
    let entry = try store.record(
        kind: .screenshot, createdAt: Date(), file: file,
        errors: ["Save file: disk full", "Show toast: no window"])
    #expect(entry.errors == ["Save file: disk full", "Show toast: no window"])
    #expect(entry.existingFile == file)
    #expect(try store.recent().first?.id == entry.id)
}

@Test @MainActor func sweepKeepsTheEntryWhenTheTempFileAgesOut() throws {
    let clock = Clock()
    let dir = tempDir()
    let files = CaptureFiles(directory: dir, retention: 60, now: { clock.t })
    let temp = try files.newFile(ext: "png")
    try Data("x".utf8).write(to: temp)
    try FileManager.default.setAttributes([.modificationDate: clock.t], ofItemAtPath: temp.path)

    let store = try HistoryStore.inMemory()
    let tempEntry = try store.record(kind: .screenshot, createdAt: clock.t, file: temp)
    let saved = try mkFile(tempDir(), "saved.png") // a Save file copy outside the sweep dir
    let savedEntry = try store.record(kind: .screenshot, createdAt: clock.t, file: saved)

    clock.t += 120 // past retention
    try files.sweep()

    let ids = try store.recent().map(\.id)
    #expect(ids.contains(tempEntry.id) && ids.contains(savedEntry.id))
    #expect(tempEntry.existingFile == nil)   // swept, entry remains
    #expect(savedEntry.existingFile == saved) // Save file copies are never swept
}

@Test func ocrReadsAPhraseFromAnImage() async throws {
    let phrase = "Wadjet sees 42"
    let img = NSImage(size: NSSize(width: 520, height: 140))
    img.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: img.size).fill()
    NSAttributedString(string: phrase, attributes: [
        .font: NSFont.systemFont(ofSize: 48),
        .foregroundColor: NSColor.black,
    ]).draw(at: NSPoint(x: 16, y: 40))
    img.unlockFocus()
    var rect = CGRect(origin: .zero, size: img.size)
    let cg = try #require(img.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    let rep = NSBitmapImageRep(cgImage: cg)
    let png = try #require(rep.representation(using: .png, properties: [:]))

    let file = tempDir().appendingPathComponent("ocr.png")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: file)

    let text = try await recognizeText(in: file)
    #expect(text.contains("Wadjet"))
    #expect(text.contains("42"))
}

// Proves History thumbnails follow Editor saves: the package's thumbnail.png is
// re-rendered while the entry's recorded file, link and deletionURL stay as the
// Workflow left them.
@Test @MainActor func editingAHistoryCanvasRefreshesItsThumbnailButNotItsFileOrLink() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = CanvasStore(directory: dir.appendingPathComponent("Canvases"))
    let image = try rasterImage()
    let file = dir.appendingPathComponent("shot.png")
    try CanvasImageCodec.png(image).write(to: file)
    let fileBytes = try Data(contentsOf: file)
    let history = try HistoryStore.inMemory()
    let entry = try history.record(kind: .screenshot, createdAt: Date(), file: file)
    entry.link = "https://example.com/a"
    entry.deletionURL = "https://example.com/d"

    let canvas = CanvasDocument(
        layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 64), scaleFactor: 2)],
        crop: CGRect(x: 0, y: 0, width: 32, height: 32), displayImages: [1: image])
    let package = try store.add(canvas, for: entry.id, createdAt: entry.createdAt)
    let thumbnail = package.appendingPathComponent("thumbnail.png")
    let before = try Data(contentsOf: thumbnail)
    #expect(entry.thumbnailFile(in: store) == thumbnail)

    // an Editor save rewrites the package — a visible change re-renders the thumbnail
    var edited = try #require(try store.canvas(for: entry.id))
    edited.crop = CGRect(x: 0, y: 0, width: 16, height: 16)
    try edited.write(to: package)

    #expect(try Data(contentsOf: thumbnail) != before)
    #expect(entry.thumbnailFile(in: store) == thumbnail)
    #expect(entry.link == "https://example.com/a")
    #expect(entry.deletionURL == "https://example.com/d")
    #expect(try Data(contentsOf: file) == fileBytes)
}

// Proves a Canvas-less entry's thumbnail is its recorded file, as before.
@Test @MainActor func thumbnailFallsBackToTheEntryFileWithoutAPackage() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = CanvasStore(directory: dir.appendingPathComponent("Canvases"))
    let file = dir.appendingPathComponent("shot.png")
    try CanvasImageCodec.png(try rasterImage()).write(to: file)
    let history = try HistoryStore.inMemory()
    let entry = try history.record(kind: .screenshot, createdAt: Date(), file: file)
    #expect(entry.thumbnailFile(in: store) == file)
}

private func rasterImage(size: Int = 64) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return try #require(context.makeImage())
}

@Test @MainActor func setOCRStoresTextOnTheRightEntry() throws {
    let store = try HistoryStore.inMemory()
    let a = try store.record(kind: .screenshot, createdAt: Date(), file: nil)
    let b = try store.record(kind: .screenshot, createdAt: Date(), file: nil)
    try store.setOCR("hello world", for: a.id)
    #expect(try store.recent().first { $0.id == a.id }?.ocrText == "hello world")
    #expect(try store.recent().first { $0.id == b.id }?.ocrText == nil)
}
