import Foundation

/// How Measure reads the Freeze Frame. The raw value is the label the app shows and stores.
public enum MeasureMode: String, CaseIterable, Codable, Sendable { case bounds = "Bounds", spacing = "Spacing", horizontal = "Horizontal", vertical = "Vertical" }

/// wadjet's config.json. Later slices add Destinations, Recording and history retention here.
public struct WadjetConfig: Codable, Equatable, Sendable {
    public var tools = Tools()
    public var folders = Folders()
    public var workflows: [Workflow] = [
        Workflow(name: "Screenshot", takes: .screenshot, steps: [.saveFile(folder: nil), .copyImage, .showToast]),
        Workflow(name: "MP4", takes: .mp4, steps: [.saveFile(folder: nil), .showToast]),
        Workflow(name: "GIF", takes: .gif, steps: [.saveFile(folder: nil), .showToast]),
    ]
    public var shortcuts: [Shortcut] = []
    public var defaultWorkflows = DefaultWorkflows()
    public init() {}
    public struct Folders: Codable, Equatable, Sendable {
        public var screenshots = "~/Pictures/Wadjet"
        public var recordings = "~/Movies/Wadjet"
        public init() {}
    }
    public struct DefaultWorkflows: Codable, Equatable, Sendable {
        public var screenshot = "Screenshot"
        public var recording = "MP4"
        public init() {}
    }
    public struct Tools: Codable, Equatable, Sendable { public var pickColour = PickColour(); public var measure = Measure(); public init() {} }
    public struct PickColour: Codable, Equatable, Sendable { public var format = ColourFormat.hex; public init() {} }
    public struct Measure: Codable, Equatable, Sendable { public var mode = MeasureMode.spacing; public init() {} }

    /// Custom so missing keys still fall back to defaults and cross-references
    /// (Shortcut.workflow, defaultWorkflows) validate against `workflows`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decodeIfPresent(Tools.self, forKey: .tools) ?? Tools()
        folders = try c.decodeIfPresent(Folders.self, forKey: .folders) ?? Folders()
        workflows = try c.decodeIfPresent([Workflow].self, forKey: .workflows) ?? WadjetConfig().workflows
        shortcuts = try c.decodeIfPresent([Shortcut].self, forKey: .shortcuts) ?? []
        defaultWorkflows = try c.decodeIfPresent(DefaultWorkflows.self, forKey: .defaultWorkflows) ?? DefaultWorkflows()

        func bad(_ msg: String, path: [CodingKey]) throws -> Never {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath + path, debugDescription: msg))
        }
        func lookup(_ name: String, recording: Bool, path: [CodingKey]) throws {
            let kinds: (CaptureKind) -> Bool = recording ? \.isRecording : { $0 == .screenshot }
            let label = recording ? "Recording" : "Screenshot"
            if !workflows.contains(where: { $0.name == name && kinds($0.takes) }) {
                try bad("no \(label) Workflow named \"\(name)\"", path: path)
            }
        }
        for (i, sc) in shortcuts.enumerated() {
            guard let wf = sc.workflow else { continue }
            let path: [CodingKey] = [CodingKeys.shortcuts, Idx(i), CodingKeys.workflow]
            guard let produces = sc.tool.produces else {
                try bad("\(sc.tool.rawValue) runs no Workflow", path: path)
            }
            try lookup(wf, recording: produces.isRecording, path: path)
        }
        // legacy configs without `defaultWorkflows` merge the factory names in —
        // if those names went away with the workflows, take the first of the
        // kind instead of rejecting the file. ConfigStore marks omitted keys via
        // userInfo so an explicitly dangling name (even a factory one) still errors.
        let omitted = decoder.userInfo[.omittedKeys] as? Set<String>
        let whole = omitted?.contains("defaultWorkflows") ?? !c.contains(.defaultWorkflows)
        for (key, name, recording) in [
            (CodingKeys.screenshot, defaultWorkflows.screenshot, false),
            (CodingKeys.recording, defaultWorkflows.recording, true),
        ] {
            let injected = whole || (omitted?.contains("defaultWorkflows.\(key.stringValue)") ?? false)
            let ok = workflows.contains { $0.name == name && (recording ? $0.takes.isRecording : $0.takes == .screenshot) }
            if !ok && injected, let first = workflows.first(where: { recording ? $0.takes.isRecording : $0.takes == .screenshot }) {
                if recording { defaultWorkflows.recording = first.name } else { defaultWorkflows.screenshot = first.name }
            } else {
                try lookup(name, recording: recording, path: [CodingKeys.defaultWorkflows, key])
            }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tools, forKey: .tools)
        try c.encode(folders, forKey: .folders)
        try c.encode(workflows, forKey: .workflows)
        try c.encode(shortcuts, forKey: .shortcuts)
        try c.encode(defaultWorkflows, forKey: .defaultWorkflows)
    }
    private enum CodingKeys: String, CodingKey {
        case tools, folders, workflows, shortcuts, defaultWorkflows, workflow, screenshot, recording
    }
    private struct Idx: CodingKey {
        var stringValue: String { String(intValue!) }
        var intValue: Int?
        init(_ i: Int) { intValue = i }
        init?(stringValue: String) { intValue = Int(stringValue) }
        init?(intValue: Int) { self.intValue = intValue }
    }
}
