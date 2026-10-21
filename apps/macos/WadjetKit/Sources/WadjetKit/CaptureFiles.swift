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

    /// `Wadjet 2026-10-17 at 14.03.22.<ext>`, or `<name>.<ext>`; adds ` 2`, ` 3`, … on collision.
    public func newFile(ext: String, name: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = CaptureName.unique(name ?? CaptureName.base(for: now())) {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0).\(ext)").path)
        }
        return directory.appendingPathComponent("\(base).\(ext)")
    }

    /// Deletes files inside `directory` whose modification date is older than
    /// `now() - retention`. One undeletable file doesn't stop the sweep; any
    /// failures surface as one thrown error afterwards. Never touches anything
    /// outside `directory`.
    public func sweep() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        let cutoff = now().addingTimeInterval(-retention)
        var failures: [Error] = []
        for name in try fm.contentsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(name)
            let age = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            guard age < cutoff else { continue }
            do { try fm.removeItem(at: url) } catch { failures.append(error) }
        }
        if let first = failures.first {
            throw failures.count == 1 ? first
                : NSError(domain: "wadjet", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "sweep: couldn't remove \(failures.count) files: \(first.localizedDescription)"])
        }
    }
}
