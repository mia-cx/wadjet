import Foundation
import Observation
import Dispatch
import Security

/// Where a secret lives. The config file stores only `{"keychain": "<account>"}`.
public struct Secret: Codable, Hashable, Sendable {
    public let account: String
    public init(account: String) { self.account = account }

    private enum Keys: String, CodingKey { case keychain }

    /// Accepts `{"keychain": "<account>"}` or a hand-typed plaintext string; the
    /// string is moved into the Keychain under a fresh account and the caller is
    /// told to rewrite the file with the reference.
    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: Keys.self),
           let account = try keyed.decodeIfPresent(String.self, forKey: .keychain) {
            self.account = account
            return
        }
        let plain = try decoder.singleValueContainer().decode(String.self)
        guard let box = decoder.userInfo[.secretMigration] as? SecretMigrationBox else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "a plaintext secret needs a keychain to migrate into"))
        }
        let account = UUID().uuidString.lowercased()
        do {
            try box.keychain.save(plain, account: account)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "couldn't save the secret to the Keychain: \(error.localizedDescription)"))
        }
        box.migrated = true
        self.account = account
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(account, forKey: .keychain)
    }
}

extension CodingUserInfoKey {
    static let secretMigration = CodingUserInfoKey(rawValue: "cx.mia.wadjet.secretMigration")!
}

/// Carries the Keychain and a "migrated" flag into one decode.
/// Confined to a single synchronous decode on the main actor, so Sendable is safe.
final class SecretMigrationBox: @unchecked Sendable {
    let keychain: any Keychain
    var migrated = false
    init(keychain: any Keychain) { self.keychain = keychain }
}

/// The Keychain as the config store needs it; tests pass an in-memory fake.
public protocol Keychain {
    func save(_ secret: String, account: String) throws
}

/// Generic-password items under one service in the login keychain.
public struct SystemKeychain: Keychain {
    private let service: String
    public init(service: String) { self.service = service }
    public func save(_ secret: String, account: String) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
        ]
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: Data(secret.utf8)] as CFDictionary)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// Why the config file couldn't be used. `location` is the coding path
/// (e.g. "tools.pickColour.format") for a value the schema rejects, nil for a
/// JSON syntax error, whose message carries Foundation's "around line L, column C".
public struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    public let file: URL
    public let location: String?
    public let message: String
    public var description: String {
        "\(file.lastPathComponent): \(location.map { "\($0): " } ?? "")\(message)"
    }
}

/// A JSON file on disk as a live, observable value. Loads synchronously, merges
/// the file over the defaults so missing keys keep working, watches the file for
/// edits (both atomic-replace and in-place writes), and never overwrites a file
/// that currently doesn't parse. Top-level keys this version doesn't model
/// are kept on every write, so a newer app's settings or a hand-added key
/// never vanish (unknown keys nested inside a modelled section are dropped).
@MainActor @Observable
public final class ConfigStore<Config: Codable & Equatable & Sendable> {
    public private(set) var value: Config
    public let file: URL

    private let defaults: Config
    private let keychain: any Keychain
    private let onError: @MainActor (ConfigError) -> Void
    /// The file rejected the last load: keep `value`, stop writing, wait for a fix.
    private var broken = false
    /// Bytes last read or written, so our own writes and repeat events are no-ops.
    private var lastData: Data?
    /// The file's JSON object from the last successful load; our writes keep
    /// its unknown top-level keys and write modelled sections wholesale.
    private var raw: Any?
    /// Top-level keys the model produces (defaults ∪ every encoded value) —
    /// only raw keys outside this set survive a write.
    private var modelledKeys: Set<String> = []
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    /// Loads `file` (creating it with `defaults` when missing), then watches it for edits.
    public init(file: URL, defaults: Config, keychain: any Keychain, onError: @escaping @MainActor (ConfigError) -> Void) {
        self.file = file
        self.defaults = defaults
        self.keychain = keychain
        self.value = defaults
        self.onError = onError
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        load(normalize: true)
        watchDirectory()
        watchFile()
    }

    isolated deinit {
        pendingReload?.cancel()
        dirSource?.cancel()
        fileSource?.cancel()
    }

    /// Applies `change`; writes the file when the value actually changed.
    /// An outside edit the watcher hasn't delivered yet loads first, so it's never overwritten.
    public func update(_ change: (inout Config) -> Void) {
        if (try? Data(contentsOf: file)) != lastData { load() }
        var v = value
        change(&v)
        guard v != value else { return }
        value = v
        if !broken { write() }
    }

    // MARK: load

    /// `normalize`: rewrite the file in canonical form if it's missing newer
    /// keys — only on the initial load, so a live edit Mia just saved is never
    /// rewritten out from under her editor.
    private func load(normalize: Bool = false) {
        guard let data = try? Data(contentsOf: file) else {
            write() // missing file: put the current value back
            return
        }
        guard data != lastData else { return }
        lastData = data
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            let base = try JSONSerialization.jsonObject(with: encoder.encode(defaults))
            let merged = try JSONSerialization.data(withJSONObject: merge(base, over: parsed))
            let decoder = JSONDecoder()
            let migration = SecretMigrationBox(keychain: keychain)
            decoder.userInfo[.secretMigration] = migration
            let v = try decoder.decode(Config.self, from: merged)
            if v != value { value = v }
            raw = parsed
            modelledKeys = Set((base as? [String: Any])?.keys.map { $0 } ?? [])
                .union(Set(((try? JSONSerialization.jsonObject(with: encoder.encode(v))) as? [String: Any])?.keys.map { $0 } ?? []))
            broken = false
            // a file missing newer keys gains them (and takes canonical form)
            if normalize, let enc = try? encoded(value), enc != data { write() }
            if migration.migrated { write() } // plaintext secrets became {"keychain": …} references
        } catch {
            broken = true
            onError(configError(error))
        }
    }

    /// `over` (the file) wins; objects merge key by key so missing keys keep defaults.
    private func merge(_ base: Any?, over: Any) -> Any {
        guard let b = base as? [String: Any], let o = over as? [String: Any] else { return over }
        var m = b
        for (k, v) in o { m[k] = merge(b[k], over: v) }
        return m
    }

    private func configError(_ error: any Error) -> ConfigError {
        if let d = error as? DecodingError {
            let ctx: DecodingError.Context = switch d {
            case .dataCorrupted(let c): c
            case .keyNotFound(_, let c): c
            case .typeMismatch(_, let c): c
            case .valueNotFound(_, let c): c
            @unknown default: .init(codingPath: [], debugDescription: d.localizedDescription)
            }
            let path = ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return ConfigError(file: file, location: path.isEmpty ? nil : path, message: ctx.debugDescription)
        }
        let ns = error as NSError
        return ConfigError(file: file, location: nil,
                           message: ns.userInfo[NSDebugDescriptionErrorKey] as? String ?? ns.localizedDescription)
    }

    // MARK: write

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// The file bytes for `v`: our value plus the file's unknown top-level
    /// keys; modelled sections are written wholesale from our value.
    private func encoded(_ v: Config) throws -> Data {
        var data: Data
        if let rawObj = raw as? [String: Any],
           let ours = try? JSONSerialization.jsonObject(with: encoder.encode(v)) as? [String: Any] {
            modelledKeys.formUnion(ours.keys)
            // shallow preserve: unknown top-level keys survive; modelled
            // sections (and any cleared keys inside them) come from our value
            let m = rawObj.filter { !modelledKeys.contains($0.key) }.merging(ours) { $1 }
            data = try JSONSerialization.data(withJSONObject: m,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } else {
            data = try encoder.encode(v)
        }
        data.append(0x0A)
        return data
    }

    private func write() {
        do {
            let data = try encoded(value)
            try data.write(to: file, options: .atomic)
            lastData = data
        } catch {
            onError(ConfigError(file: file, location: nil, message: error.localizedDescription))
        }
        watchFile() // our atomic write swapped the inode; re-arm on the new one
    }

    // MARK: watch

    /// Editors replace the file (atomic rename) or write it in place, so watch
    /// both the directory and the file itself.
    private func watchDirectory() {
        let fd = open(file.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in
            // the source fires on .main, so the hop is free and safe
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        dirSource = s
    }

    /// Opens a fresh source on the file; cancels the old one because the inode may have changed.
    private func watchFile() {
        fileSource?.cancel()
        let fd = open(file.path, O_EVTONLY)
        guard fd >= 0 else { fileSource = nil; return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                          eventMask: [.write, .extend, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in
            // the source fires on .main, so the hop is free and safe
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        fileSource = s
    }

    /// Debounce: in-place writes truncate first, so an immediate reload would
    /// read a half-written file and report a spurious syntax error.
    private func scheduleReload() {
        pendingReload?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        pendingReload = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    private func reload() {
        load()
        watchFile() // a replace swap means the source sat on the old inode
    }
}
