import Foundation
import SwiftData

/// One Capture's permanent record: kind, when, where the file lives, and what
/// its Steps did wrong. `link`, `deletionURL`, and `destination` stay nil until
/// Destinations (#34) fill them. The entry outlives its file — the retention
/// sweep deletes temp Captures but never their entries; `existingFile` reports
/// whether the file is still on disk.
@Model public final class HistoryEntry {
    public var id: UUID
    var kindRaw: String
    public var createdAt: Date
    public var filePath: String?
    public var link: String?
    public var deletionURL: String?
    public var destination: String?
    public var ocrText: String?
    public var errors: [String]

    public init(id: UUID = UUID(), kind: CaptureKind, createdAt: Date, file: URL?, errors: [String] = []) {
        self.id = id
        kindRaw = kind.rawValue
        self.createdAt = createdAt
        filePath = file?.path
        link = nil
        deletionURL = nil
        destination = nil
        ocrText = nil
        self.errors = errors
    }

    public var kind: CaptureKind { CaptureKind(rawValue: kindRaw) ?? .screenshot }

    /// The capture's file, only while it still exists on disk.
    public var existingFile: URL? {
        guard let filePath, FileManager.default.fileExists(atPath: filePath) else { return nil }
        return URL(fileURLWithPath: filePath)
    }
}

/// SwiftData-backed store of every Capture. Owns the ModelContainer; all reads
/// and writes go through it so the app never touches model contexts directly.
/// Lives at `Application Support/wadjet/History.store`; `inMemory()` for tests.
@MainActor public final class HistoryStore {
    private let container: ModelContainer

    public init(url: URL) throws {
        container = try ModelContainer(
            for: HistoryEntry.self,
            configurations: ModelConfiguration(url: url)
        )
    }

    /// An ephemeral store — the same queries, nothing touches disk.
    public static func inMemory() throws -> HistoryStore {
        try HistoryStore(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private init(configuration: ModelConfiguration) throws {
        container = try ModelContainer(for: HistoryEntry.self, configurations: configuration)
    }

    /// Records a finished Capture and persists it immediately.
    @discardableResult
    public func record(kind: CaptureKind, createdAt: Date, file: URL?, errors: [String] = []) throws -> HistoryEntry {
        let entry = HistoryEntry(kind: kind, createdAt: createdAt, file: file, errors: errors)
        container.mainContext.insert(entry)
        try container.mainContext.save()
        return entry
    }

    /// Attaches recognized text to a Screenshot entry after OCR finishes.
    public func setOCR(_ text: String, for id: UUID) throws {
        var fetch = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 1
        guard let entry = try container.mainContext.fetch(fetch).first else { return }
        entry.ocrText = text
        try container.mainContext.save()
    }

    /// The newest `limit` Captures, newest first.
    public func recent(limit: Int = 10) throws -> [HistoryEntry] {
        var fetch = FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        fetch.fetchLimit = limit
        return try container.mainContext.fetch(fetch)
    }
}
