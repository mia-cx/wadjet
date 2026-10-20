import Foundation

/// The screenshots folder's two halves of every Screenshot: `original/` holds
/// History's Canvases, `flattened/` the images Save file writes. Both share a
/// base name, so a Canvas and its image pair up in Finder.
public struct ScreenshotFolders: Equatable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public var original: URL { root.appendingPathComponent("original", isDirectory: true) }
    public var flattened: URL { root.appendingPathComponent("flattened", isDirectory: true) }
}

/// Capture file names: `Wadjet 2026-10-17 at 14.03.22`, then ` 2`, ` 3`, … like Finder.
public enum CaptureName {
    public static func base(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX") // names never vary with region
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Wadjet \(f.string(from: date))"
    }

    /// The first of `base`, `base 2`, `base 3`, … that `isTaken` rejects.
    public static func unique(_ base: String, isTaken: (String) -> Bool) -> String {
        var name = base, n = 2
        while isTaken(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// Names in `directories` with their extensions removed; a missing directory has none.
    public static func takenBaseNames(in directories: [URL]) -> Set<String> {
        Set(directories.flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .map { ($0 as NSString).deletingPathExtension }
        })
    }
}

/// One container Canvas moving into `original/` under its capture's date-based name.
public struct CanvasMigrationMove: Equatable, Sendable {
    public let id: UUID
    public let from: URL
    public let to: URL
}

/// Plans the move of History's container Canvases (`<UUID>.wadjet`) into
/// `original/`. Oldest capture first, so a same-second collision gives the
/// later capture the ` 2` suffix, and existing names are never reused.
public enum CanvasMigrationPlan {
    public struct Source: Equatable, Sendable {
        public let id: UUID
        public let url: URL
        public let createdAt: Date
        public init(id: UUID, url: URL, createdAt: Date) {
            self.id = id; self.url = url; self.createdAt = createdAt
        }
    }

    public static func moves(_ sources: [Source], into directory: URL, taken: Set<String>,
                             timeZone: TimeZone = .current) -> [CanvasMigrationMove] {
        var taken = taken
        return sources.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map { source in
                let name = CaptureName.unique(CaptureName.base(for: source.createdAt, timeZone: timeZone),
                    isTaken: taken.contains)
                taken.insert(name)
                return CanvasMigrationMove(id: source.id, from: source.url,
                    to: directory.appendingPathComponent("\(name).wadjet", isDirectory: false))
            }
    }
}
