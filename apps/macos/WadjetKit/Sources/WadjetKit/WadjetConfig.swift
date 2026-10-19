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
    /// Security-scoped bookmarks for folders chosen outside the sandbox's
    /// Pictures/Movies grants; key is the path as written in config.json.
    public var bookmarks: [String: Data] = [:]
    /// Days before temporary Capture files are swept; their history entries stay.
    public var retentionDays = 7
    public var recording = Recording()
    public var capture = Capture()
    public var markup = Markup()
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
    public struct Tools: Codable, Equatable, Sendable {
        public var pickColour = PickColour(); public var measure = Measure(); public var region = Region()
        public init() {}
        public init(from decoder: Decoder) throws { // members keep defaults when a section is partial
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pickColour = try c.decodeIfPresent(PickColour.self, forKey: .pickColour) ?? PickColour()
            measure = try c.decodeIfPresent(Measure.self, forKey: .measure) ?? Measure()
            region = try c.decodeIfPresent(Region.self, forKey: .region) ?? Region()
        }
    }
    public struct PickColour: Codable, Equatable, Sendable { public var format = ColourFormat.hex; public init() {} }
    public struct Measure: Codable, Equatable, Sendable { public var mode = MeasureMode.spacing; public init() {} }
    public struct Region: Codable, Equatable, Sendable {
        public var confirm = RegionConfirm.release
        public init() {}
        public init(from decoder: Decoder) throws {
            confirm = try decoder.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(RegionConfirm.self, forKey: .confirm) ?? .release
        }
    }
    /// `release` runs the capture at mouse-up; `manual` keeps the selection
    /// editable with handles until confirmed (button / Return)
    public enum RegionConfirm: String, Codable, Equatable, Sendable { case release, manual }
    /// Video capture shape: `resolution` is the longest output edge in pixels
    /// (the source is never upscaled, only scaled down), `fps` the frame rate.
    public struct Recording: Codable, Equatable, Sendable {
        public var resolution = 1920
        public var fps = 30
        public init() {}
    }
    /// `freeze` — take a Freeze Frame when a Tool opens; off leaves the desktop
    /// live and shoots at confirm (Utilities always freeze — they read pixels).
    /// `cursor` — the cursor's default in Screenshots and Recordings; the Tool
    /// menu overrides it per capture.
    public struct Capture: Codable, Equatable, Sendable {
        public var freeze = true
        public var cursor = true
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            freeze = try c.decodeIfPresent(Bool.self, forKey: .freeze) ?? true
            cursor = try c.decodeIfPresent(Bool.self, forKey: .cursor) ?? true
        }
    }
    /// Markup settings: per-Tool settings keyed by the Markup Tool's raw name
    /// ("draw"), and the colours used in Markup, ranked for the colour
    /// control's swatches (hex "#RRGGBB").
    public struct Markup: Codable, Equatable, Sendable {
        public var tools: [String: MarkupTool] = [:]
        public var recentColours = FrecencyRanker<String>()
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tools = try c.decodeIfPresent([String: MarkupTool].self, forKey: .tools) ?? [:]
            recentColours = try c.decodeIfPresent(FrecencyRanker<String>.self, forKey: .recentColours) ?? FrecencyRanker()
        }
    }
    /// one Markup Tool's settings; later slices add theirs (Line ends, Text font…) here
    public struct MarkupTool: Codable, Equatable, Sendable {
        /// nil until the user restyles the Tool; the app then uses the Tool's built-in default
        public var style: AnnotationStyle?
        public init(style: AnnotationStyle? = nil) { self.style = style }
    }

    /// Custom so missing keys still fall back to defaults and cross-references
    /// (Shortcut.workflow, defaultWorkflows) validate against `workflows`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decodeIfPresent(Tools.self, forKey: .tools) ?? Tools()
        folders = try c.decodeIfPresent(Folders.self, forKey: .folders) ?? Folders()
        workflows = try c.decodeIfPresent([Workflow].self, forKey: .workflows) ?? WadjetConfig().workflows
        shortcuts = try c.decodeIfPresent([Shortcut].self, forKey: .shortcuts) ?? []
        defaultWorkflows = try c.decodeIfPresent(DefaultWorkflows.self, forKey: .defaultWorkflows) ?? DefaultWorkflows()
        bookmarks = try c.decodeIfPresent([String: Data].self, forKey: .bookmarks) ?? [:]
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7
        recording = try c.decodeIfPresent(Recording.self, forKey: .recording) ?? Recording()
        capture = try c.decodeIfPresent(Capture.self, forKey: .capture) ?? Capture()
        markup = try c.decodeIfPresent(Markup.self, forKey: .markup) ?? Markup()

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
        if retentionDays < 1 {
            try bad("retentionDays must be at least 1", path: [CodingKeys.retentionDays])
        }
        if recording.resolution < 2 {
            try bad("recording.resolution must be at least 2", path: [CodingKeys.recording, CodingKeys.resolution])
        }
        if !(1...120).contains(recording.fps) {
            try bad("recording.fps must be 1...120", path: [CodingKeys.recording, CodingKeys.fps])
        }
        try lookup(defaultWorkflows.screenshot, recording: false, path: [CodingKeys.defaultWorkflows, CodingKeys.screenshot])
        try lookup(defaultWorkflows.recording, recording: true, path: [CodingKeys.defaultWorkflows, CodingKeys.recording])
    }
    /// Renames a Workflow and every reference (Shortcuts, defaultWorkflows).
    public mutating func renameWorkflow(from old: String, to new: String) {
        for i in workflows.indices where workflows[i].name == old { workflows[i].name = new }
        for i in shortcuts.indices where shortcuts[i].workflow == old { shortcuts[i].workflow = new }
        if defaultWorkflows.screenshot == old { defaultWorkflows.screenshot = new }
        if defaultWorkflows.recording == old { defaultWorkflows.recording = new }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tools, forKey: .tools)
        try c.encode(folders, forKey: .folders)
        try c.encode(workflows, forKey: .workflows)
        try c.encode(shortcuts, forKey: .shortcuts)
        try c.encode(defaultWorkflows, forKey: .defaultWorkflows)
        try c.encode(bookmarks, forKey: .bookmarks)
        try c.encode(retentionDays, forKey: .retentionDays)
        try c.encode(recording, forKey: .recording)
        try c.encode(capture, forKey: .capture)
        try c.encode(markup, forKey: .markup)
    }
    private enum CodingKeys: String, CodingKey {
        case tools, folders, workflows, shortcuts, defaultWorkflows, bookmarks, retentionDays, recording, resolution, fps, workflow, screenshot, capture, markup
    }
    private struct Idx: CodingKey {
        var stringValue: String { String(intValue!) }
        var intValue: Int?
        init(_ i: Int) { intValue = i }
        init?(stringValue: String) { intValue = Int(stringValue) }
        init?(intValue: Int) { self.intValue = intValue }
    }
}
