import Foundation

/// `~/x` → the real home directory. `NSHomeDirectory()` would return the
/// sandbox container, which is not where files belong.
public func expandingTilde(_ path: String) -> URL {
    guard path.hasPrefix("~") else { return URL(fileURLWithPath: path) }
    let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
    return URL(fileURLWithPath: home + String(path.dropFirst()))
}

/// Names and sweeps the temporary files captures land in. Files are "Wadjet
/// <date> at <time>.<ext>"; a `sweep` removes anything older than `retention`
/// inside `directory` — Save file copies live elsewhere and are never swept.
public struct CaptureFiles: Sendable {
    public let directory: URL
    public let retention: TimeInterval
    let now: @Sendable () -> Date
    public init(directory: URL, retention: TimeInterval = 7 * 24 * 3600, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.retention = retention
        self.now = now
    }

    /// `Wadjet 2026-10-17 at 14.03.22.<ext>`; adds ` 2`, ` 3`, … on collision.
    public func newFile(ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = directory.appendingPathComponent("Wadjet \(f.string(from: now()))")
        var url = base.appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Deletes files inside `directory` whose modification date is older than
    /// `now() - retention`. Never touches anything outside `directory`.
    public func sweep() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        let cutoff = now().addingTimeInterval(-retention)
        for name in try fm.contentsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(name)
            let age = (try url.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate ?? .distantFuture
            if age < cutoff { try fm.removeItem(at: url) }
        }
    }
}
