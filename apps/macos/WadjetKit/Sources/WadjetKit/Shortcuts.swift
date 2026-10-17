import Foundation

/// The app-side Tool, named so config.json never has to match internal cases.
public enum ToolID: String, Codable, CaseIterable, Sendable {
    case captureRegion, captureWindow, captureScreen
    case recordRegion, recordWindow, recordScreen
    case pickColour, copyText, measure

    /// What the Tool's capture feeds a Workflow, if it captures at all.
    public var produces: CaptureKind? {
        switch self {
        case .captureRegion, .captureWindow, .captureScreen: .screenshot
        case .recordRegion, .recordWindow, .recordScreen: .mp4 // any recording
        default: nil
        }
    }
}

/// A parsed `"cmd+shift+2"`-style string: ANSI virtual key code + Carbon
/// modifier mask. Codable as the string; canonical form is
/// `ctrl+opt+shift+cmd+<key>`.
public struct KeyCombo: Equatable, Sendable, CustomStringConvertible {
    public let keyCode: Int
    public let carbonModifiers: Int

    static let cmd = 0x100, shift = 0x200, opt = 0x800, ctrl = 0x1000

    /// ANSI virtual key codes (kVK_*), spelled out so WadjetKit needs no Carbon.
    static let keys: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]
    // canonical name per key code
    static let keyNames: [Int: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15",
        106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
    ]

    public init?(keyCode: Int, carbonModifiers: Int) {
        guard Self.keyNames[keyCode] != nil || (Self.keys.values.contains(keyCode)) else { return nil }
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers & (Self.cmd | Self.shift | Self.opt | Self.ctrl)
    }

    /// "cmd+shift+2", "ctrl+opt+r", "cmd+f5", "shift+space". A modifier is
    /// required, except for f-keys (touch-bar Macs made f-keys the escape hatch).
    public init?(_ string: String) {
        var mods = 0, key: Int? = nil
        for part in string.lowercased().split(separator: "+") {
            let p = String(part)
            switch p {
            case "cmd", "command": mods |= Self.cmd
            case "shift": mods |= Self.shift
            case "opt", "option", "alt": mods |= Self.opt
            case "ctrl", "control": mods |= Self.ctrl
            default:
                guard let k = Self.keys[p], key == nil else { return nil }
                key = k
            }
        }
        guard let key else { return nil }
        let isF = (Self.keyNames[key] ?? "").hasPrefix("f") && key >= 64
        guard mods != 0 || isF else { return nil }
        self.init(keyCode: key, carbonModifiers: mods)
    }

    public var description: String {
        var parts: [String] = []
        if carbonModifiers & Self.ctrl != 0 { parts.append("ctrl") }
        if carbonModifiers & Self.opt != 0 { parts.append("opt") }
        if carbonModifiers & Self.shift != 0 { parts.append("shift") }
        if carbonModifiers & Self.cmd != 0 { parts.append("cmd") }
        parts.append(Self.keyNames[keyCode] ?? "?")
        return parts.joined(separator: "+")
    }
}

extension KeyCombo: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = KeyCombo(s) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "unknown key combo \"\(s)\""))
        }
        self = c
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Options a Shortcut applies before its Tool triggers.
public struct ShortcutOptions: Codable, Equatable, Sendable {
    public var countdown: Int?
    public var systemAudio: Bool?
    public var microphone: Bool?
    public var cursor: Bool?
    public var clickCircles: Bool?
    public init(countdown: Int? = nil, systemAudio: Bool? = nil, microphone: Bool? = nil,
                cursor: Bool? = nil, clickCircles: Bool? = nil) {
        self.countdown = countdown; self.systemAudio = systemAudio; self.microphone = microphone
        self.cursor = cursor; self.clickCircles = clickCircles
    }
}

/// A hotkey that opens a Tool with set options, optionally naming the Workflow
/// that processes the capture.
public struct Shortcut: Codable, Equatable, Sendable {
    public var keys: KeyCombo
    public var tool: ToolID
    public var workflow: String?
    public var options: ShortcutOptions
    public init(keys: KeyCombo, tool: ToolID, workflow: String? = nil, options: ShortcutOptions = .init()) {
        self.keys = keys; self.tool = tool; self.workflow = workflow; self.options = options
    }
    /// `options` is optional in config.json — absent means "the app's defaults".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keys = try c.decode(KeyCombo.self, forKey: .keys)
        tool = try c.decode(ToolID.self, forKey: .tool)
        workflow = try c.decodeIfPresent(String.self, forKey: .workflow)
        options = try c.decodeIfPresent(ShortcutOptions.self, forKey: .options) ?? ShortcutOptions()
    }
    private enum CodingKeys: String, CodingKey { case keys, tool, workflow, options }
}
