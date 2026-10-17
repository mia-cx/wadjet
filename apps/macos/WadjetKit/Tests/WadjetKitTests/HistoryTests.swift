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

@Test @MainActor func setOCRStoresTextOnTheRightEntry() throws {
    let store = try HistoryStore.inMemory()
    let a = try store.record(kind: .screenshot, createdAt: Date(), file: nil)
    let b = try store.record(kind: .screenshot, createdAt: Date(), file: nil)
    try store.setOCR("hello world", for: a.id)
    #expect(try store.recent().first { $0.id == a.id }?.ocrText == "hello world")
    #expect(try store.recent().first { $0.id == b.id }?.ocrText == nil)
}
