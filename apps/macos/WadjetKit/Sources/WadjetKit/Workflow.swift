import Foundation

/// What a Workflow consumes: a finished Screenshot file or a finished Recording.
public enum CaptureKind: String, Codable, Sendable {
    case screenshot, mp4, gif
    public var isRecording: Bool { self != .screenshot }
}

/// One action in a Workflow. Steps run in order on the captured file; a Step
/// that throws is reported and skipped.
public enum Step: Equatable, Sendable {
    case saveFile(folder: String?) // nil = the default folder for the kind
    case copyImage
    case showToast

    public var title: String {
        switch self {
        case .saveFile: return "Save file"
        case .copyImage: return "Copy image"
        case .showToast: return "Show toast"
        }
    }
}

extension Step: Codable {
    private enum CodingKeys: String, CodingKey { case type, folder }
    private enum Kind: String, Codable { case saveFile, copyImage, showToast }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .saveFile: self = .saveFile(folder: try c.decodeIfPresent(String.self, forKey: .folder))
        case .copyImage: self = .copyImage
        case .showToast: self = .showToast
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .saveFile(let folder):
            try c.encode(Kind.saveFile, forKey: .type)
            if let folder { try c.encode(folder, forKey: .folder) }
        case .copyImage: try c.encode(Kind.copyImage, forKey: .type)
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
        // Copy image pastes pixels; a Recording has none
        if takes.isRecording, steps.contains(.copyImage) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath + [CodingKeys.steps],
                                      debugDescription: "Copy image only works on Screenshots; use Copy file for Recordings"))
        }
    }
    private enum CodingKeys: String, CodingKey { case name, takes, steps }
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
    func showToast(_ file: URL, run: UUID) async throws
}

/// Drives a captured file through a Workflow's Steps, strictly in order —
/// sequential execution is what keeps clipboard order when a later Step also
/// writes to the pasteboard. A failing Step is reported and skipped.
public struct WorkflowRunner: Sendable {
    let effects: any WorkflowEffects
    public init(effects: any WorkflowEffects) { self.effects = effects }
    public func run(_ file: URL, through workflow: Workflow, defaultFolder: URL, id: UUID = UUID()) -> AsyncStream<RunEvent> {
        AsyncStream { continuation in
            Task {
                var saved: [URL] = [], errors: [String] = []
                for (i, step) in workflow.steps.enumerated() {
                    continuation.yield(.started(i, step))
                    do {
                        switch step {
                        case .saveFile(let folder):
                            saved.append(try Self.save(file, into: folder.map { expandingTilde($0) } ?? defaultFolder))
                        case .copyImage: try await effects.copyImage(file, run: id)
                        case .showToast: try await effects.showToast(file, run: id)
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
    static func save(_ file: URL, into dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dst = dir.appendingPathComponent(file.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = dir.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent) \(n).\(file.pathExtension)")
            n += 1
        }
        try FileManager.default.copyItem(at: file, to: dst)
        return dst
    }
}
