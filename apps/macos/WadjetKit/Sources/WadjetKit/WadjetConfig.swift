import Foundation

/// How Measure reads the Freeze Frame. The raw value is the label the app shows and stores.
public enum MeasureMode: String, CaseIterable, Codable, Sendable { case bounds = "Bounds", spacing = "Spacing", horizontal = "Horizontal", vertical = "Vertical" }

/// wadjet's config.json. Later slices add Shortcuts, Workflows, Destinations, Recording, history retention and save folders here.
public struct WadjetConfig: Codable, Equatable, Sendable {
    public var tools = Tools()
    public init() {}
    public struct Tools: Codable, Equatable, Sendable { public var pickColour = PickColour(); public var measure = Measure(); public init() {} }
    public struct PickColour: Codable, Equatable, Sendable { public var format = ColourFormat.hex; public init() {} }
    public struct Measure: Codable, Equatable, Sendable { public var mode = MeasureMode.spacing; public init() {} }
}
