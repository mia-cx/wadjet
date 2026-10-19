import Foundation

/// The app-side Tool, named so config.json never has to match internal cases.
public enum ToolID: String, Codable, CaseIterable, Sendable {
    case captureRegion, captureWindow, captureScreen
    case recordRegion, recordWindow, recordScreen
    case pickColour, copyText, measure
    /// Markup Tools, named in config.json like any Tool; later Markup Tools join as cases
    case eraser, draw, text, censor, shapes, counter, magnify

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
    /// aliases that parse but never become the canonical printed name
    static let aliases: Set<String> = ["enter", "esc", "backspace"]
    // canonical name per key code, inverted from `keys` minus the aliases
    static let keyNames: [Int: String] = {
        var m: [Int: String] = [:]
        for (name, code) in keys.sorted(by: { $0.key < $1.key }) where !aliases.contains(name) {
            m[code] = m[code] ?? name
        }
        return m
    }()

    public init?(keyCode: Int, carbonModifiers: Int) {
        guard Self.keyNames[keyCode] != nil else { return nil }
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
        let isF = (1...20).contains { Self.keys["f\($0)"] == key }
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
    /// `false`: Window/Screen Tools capture at once — the pointer's display or
    /// the focused window — without the Freeze Frame pick
    public var confirm: Bool?
    public init(countdown: Int? = nil, systemAudio: Bool? = nil, microphone: Bool? = nil,
                cursor: Bool? = nil, clickCircles: Bool? = nil, confirm: Bool? = nil) {
        self.countdown = countdown; self.systemAudio = systemAudio; self.microphone = microphone
        self.cursor = cursor; self.clickCircles = clickCircles
        self.confirm = confirm
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
