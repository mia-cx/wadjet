import Foundation

/// How Measure reads the Freeze Frame. The raw value is the label the app shows and stores.
public enum MeasureMode: String, CaseIterable, Codable, Sendable { case bounds = "Bounds", spacing = "Spacing", horizontal = "Horizontal", vertical = "Vertical" }

/// wadjet's config.json. Later slices add Shortcuts, Destinations, Recording and history retention here.
public struct WadjetConfig: Codable, Equatable, Sendable {
    public var tools = Tools()
    public var folders = Folders()
    public var workflows: [Workflow] = [
        Workflow(name: "Screenshot", takes: .screenshot, steps: [.saveFile(folder: nil), .copyImage, .showToast]),
        Workflow(name: "MP4", takes: .mp4, steps: [.saveFile(folder: nil), .showToast]),
        Workflow(name: "GIF", takes: .gif, steps: [.saveFile(folder: nil), .showToast]),
    ]
    public init() {}
    public struct Folders: Codable, Equatable, Sendable {
        public var screenshots = "~/Pictures/Wadjet"
        public var recordings = "~/Movies/Wadjet"
        public init() {}
    }
    public struct Tools: Codable, Equatable, Sendable { public var pickColour = PickColour(); public var measure = Measure(); public init() {} }
    public struct PickColour: Codable, Equatable, Sendable { public var format = ColourFormat.hex; public init() {} }
    public struct Measure: Codable, Equatable, Sendable { public var mode = MeasureMode.spacing; public init() {} }
}
