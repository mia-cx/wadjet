import Foundation

/// What a Workflow consumes: a finished Screenshot file or a finished Recording.
public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case screenshot, mp4, gif
    public var isRecording: Bool { self != .screenshot }
    /// Display name for pickers and menus ("Screenshot", "MP4", "GIF").
    public var title: String {
        switch self { case .screenshot: "Screenshot"; case .mp4: "MP4"; case .gif: "GIF" }
    }
}

/// Save file's output; image keeps the capture format, Canvas keeps editable layers.
public enum SaveFileFormat: String, Codable, CaseIterable, Sendable {
    case image, canvas
}

/// One action in a Workflow. Steps run in order; a failing Step is reported and skipped.
public enum Step: Equatable, Sendable {
    case saveFile(folder: String?, format: SaveFileFormat = .image) // nil = the default folder for the kind
    case copyImage
    case copyFile
    case openIn(app: String?) // bundle identifier; nil = the file type's default app
    case pin
    case showToast

    public var title: String {
        switch self {
        case .saveFile: return "Save file"
        case .copyImage: return "Copy image"
        case .copyFile: return "Copy file"
        case .openIn: return "Open in an app"
        case .pin: return "Pin to screen"
        case .showToast: return "Show toast"
        }
    }

    /// One instance of every Step valid for a capture kind (for "add Step" menus).
    public static func allowed(for kind: CaptureKind) -> [Step] {
        [saveFile(folder: nil), .copyImage, .copyFile, .openIn(app: nil), .pin, .showToast]
            .filter { kind == .screenshot || $0.worksOnRecordings }
    }

    /// Steps that only make sense on a Screenshot get this as their config error.
    var worksOnRecordings: Bool {
        switch self {
        case .saveFile(_, .canvas): return false
        case .copyImage, .pin: return false
        default: return true
        }
    }
    var recordingsError: String {
        switch self {
        case .saveFile(_, .canvas): return "Canvas format only works on Screenshots"
        case .copyImage: return "Copy image only works on Screenshots; use Copy file for Recordings"
        case .pin: return "Pin to screen only works on Screenshots"
        default: return ""
        }
    }
}

extension Step: Codable {
    private enum CodingKeys: String, CodingKey { case type, folder, format, app }
    private enum Kind: String, Codable { case saveFile, copyImage, copyFile, openIn, pin, showToast }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .saveFile: self = .saveFile(folder: try c.decodeIfPresent(String.self, forKey: .folder),
            format: try c.decodeIfPresent(SaveFileFormat.self, forKey: .format) ?? .image)
        case .copyImage: self = .copyImage
        case .copyFile: self = .copyFile
        case .openIn: self = .openIn(app: try c.decodeIfPresent(String.self, forKey: .app))
        case .pin: self = .pin
        case .showToast: self = .showToast
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .saveFile(let folder, let format):
            try c.encode(Kind.saveFile, forKey: .type)
            if let folder { try c.encode(folder, forKey: .folder) }
            if format != .image { try c.encode(format, forKey: .format) }
        case .copyImage: try c.encode(Kind.copyImage, forKey: .type)
        case .copyFile: try c.encode(Kind.copyFile, forKey: .type)
        case .openIn(let app):
            try c.encode(Kind.openIn, forKey: .type)
            if let app { try c.encode(app, forKey: .app) }
        case .pin: try c.encode(Kind.pin, forKey: .type)
        case .showToast: try c.encode(Kind.showToast, forKey: .type)
        }
    }
}

/// A named sequence of Steps the runner drives for one capture.
public struct Workflow: Codable, Equatable, Sendable {
    public var name: String
    public var takes: CaptureKind
    public var steps: [Step]
    public init(name: String, takes: CaptureKind, steps: [Step]) {
        self.name = name; self.takes = takes; self.steps = steps
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        takes = try c.decode(CaptureKind.self, forKey: .takes)
        steps = try c.decode([Step].self, forKey: .steps)
        // a Recording has no pixels, so image Steps are config errors at the step's index
        if takes.isRecording, let i = steps.firstIndex(where: { !$0.worksOnRecordings }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath + [CodingKeys.steps, Idx(i)],
                                      debugDescription: steps[i].recordingsError))
        }
    }
    private enum CodingKeys: String, CodingKey { case name, takes, steps }
    private struct Idx: CodingKey {
        var stringValue: String { String(intValue!) }
        var intValue: Int?
        init(_ i: Int) { intValue = i }
        init?(stringValue: String) { intValue = Int(stringValue) }
        init?(intValue: Int) { self.intValue = intValue }
    }
}

/// One capture's progress through a Workflow, in Step order.
public enum RunEvent: Equatable, Sendable {
    case started(Int, Step)
    case finished(Int, Step)
    case failed(Int, Step, String)
    case done(saved: [URL], errors: [String])
}

/// The app supplies the Steps only it can perform (pasteboard, UI).
public protocol WorkflowEffects: Sendable {
    func copyImage(_ file: URL, run: UUID) async throws
    func copyFile(_ file: URL, run: UUID) async throws
    func open(_ file: URL, app: String?, run: UUID) async throws
    /// Pin gets the run's current image and its Canvas (the package the run
    /// was started with, never a Save file copy); nil when the run has none.
    func pin(_ file: URL, canvas: URL?, run: UUID) async throws
    func showToast(_ file: URL, run: UUID) async throws
}

/// Drives a captured file through a Workflow's Steps, strictly in order —
/// sequential execution is what keeps clipboard order when a later Step also
/// writes to the pasteboard. A failing Step is reported and skipped.
///
/// Every effect receives the run's *current* file — `saved.last` once a Save
/// file Step has run, else the temp capture. A Workflow that saves first hands
/// later Steps (Copy file, Open in an app) the copy outside
/// the sandbox container, which other apps can read without a prompt.
/// Copy image, Pin and Show toast always use the latest image copy, even after
/// Save Canvas. The Canvas URL travels alongside the image, never replacing it;
/// Pin receives it too.
public struct WorkflowRunner: Sendable {
    let effects: any WorkflowEffects
    public init(effects: any WorkflowEffects) { self.effects = effects }
    public func run(_ file: URL, through workflow: Workflow, defaultFolder: URL, id: UUID = UUID(),
                    canvas: URL? = nil) -> AsyncStream<RunEvent> {
        AsyncStream { continuation in
            Task {
                var saved: [URL] = [], errors: [String] = []
                var currentImage = file
                for (i, step) in workflow.steps.enumerated() {
                    continuation.yield(.started(i, step))
                    let current = saved.last ?? file
                    do {
                        switch step {
                        case .saveFile(let folder, let format):
                            let directory = folder.map { expandingTilde($0) } ?? defaultFolder
                            if format == .canvas {
                                guard let canvas else { throw CanvasDocumentError.invalidPackage("Screenshot has no Canvas") }
                                saved.append(try Self.save(canvas, into: directory,
                                    name: file.deletingPathExtension().lastPathComponent + ".wadjet"))
                            } else {
                                currentImage = try Self.save(file, into: directory)
                                saved.append(currentImage)
                            }
                        case .copyImage: try await effects.copyImage(currentImage, run: id)
                        case .copyFile: try await effects.copyFile(current, run: id)
                        case .openIn(let app): try await effects.open(current, app: app, run: id)
                        case .pin: try await effects.pin(currentImage, canvas: canvas, run: id)
                        case .showToast: try await effects.showToast(currentImage, run: id)
                        }
                        continuation.yield(.finished(i, step))
                    } catch {
                        let e = "\(step.title): \(error.localizedDescription)"
                        errors.append(e)
                        continuation.yield(.failed(i, step, e))
                    }
                }
                continuation.yield(.done(saved: saved, errors: errors))
                continuation.finish()
            }
        }
    }
    /// Copy `file` into `dir` under its own name (` 2`, ` 3`, … on collision).
    static func save(_ file: URL, into dir: URL, name: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent(name ?? file.lastPathComponent)
        var dst = base
        var n = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = dir.appendingPathComponent("\(base.deletingPathExtension().lastPathComponent) \(n).\(base.pathExtension)")
            n += 1
        }
        try FileManager.default.copyItem(at: file, to: dst)
        return dst
    }
}
