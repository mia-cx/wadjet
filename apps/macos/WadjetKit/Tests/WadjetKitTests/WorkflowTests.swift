import Testing
import Foundation
import WadjetKit

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}
private func mkFile(_ dir: URL, _ name: String = "in.png") throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent(name)
    try Data("png".utf8).write(to: f)
    return f
}

final class FakeEffects: WorkflowEffects, @unchecked Sendable {
    private(set) var order: [String] = []
    private(set) var files: [URL] = []
    private(set) var pinnedCanvases: [URL?] = []
    func copyImage(_ file: URL, run: UUID) async throws { order.append("copy"); files.append(file) }
    func copyFile(_ file: URL, run: UUID) async throws { order.append("copyFile"); files.append(file) }
    func open(_ file: URL, app: String?, run: UUID) async throws { order.append("open"); files.append(file) }
    func pin(_ file: URL, canvas: URL?, run: UUID) async throws { order.append("pin"); files.append(file); pinnedCanvases.append(canvas) }
    func showToast(_ file: URL, run: UUID) async throws { order.append("toast"); files.append(file) }
}

// injectable clock for CaptureFiles' `now:` — a @Sendable closure can't hold a var
private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_700_000_000) }

// a Step whose copy suspends until `open()` — proves run B isn't held back
private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { isOpen = true; waiter?.resume(); waiter = nil }
}
private final class GatedEffects: WorkflowEffects, @unchecked Sendable {
    let gate: Gate
    init(_ g: Gate) { gate = g }
    func copyImage(_ file: URL, run: UUID) async throws { await gate.wait() }
    func copyFile(_ file: URL, run: UUID) async throws {}
    func open(_ file: URL, app: String?, run: UUID) async throws {}
    func pin(_ file: URL, canvas: URL?, run: UUID) async throws {}
    func showToast(_ file: URL, run: UUID) async throws {}
}

@MainActor
struct WorkflowTests {
    @Test func stepsRunInOrderWithOwnOptions() async throws {
        let dir = tempDir(), a = tempDir(), b = tempDir()
        let file = try mkFile(dir)
        let fx = FakeEffects()
        let runner = WorkflowRunner(effects: fx)
        let wf = Workflow(name: "w", takes: .screenshot, steps: [.saveFile(folder: a.path), .copyImage, .saveFile(folder: b.path), .showToast])
        var events: [RunEvent] = []
        for await e in runner.run(file, through: wf, defaultFolder: tempDir()) { events.append(e) }
        #expect(events == [
            .started(0, .saveFile(folder: a.path)), .finished(0, .saveFile(folder: a.path)),
            .started(1, .copyImage), .finished(1, .copyImage),
            .started(2, .saveFile(folder: b.path)), .finished(2, .saveFile(folder: b.path)),
            .started(3, .showToast), .finished(3, .showToast),
            .done(saved: [a.appendingPathComponent("in.png"), b.appendingPathComponent("in.png")], errors: []),
        ])
        #expect(fx.order == ["copy", "toast"])
        #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("in.png").path))
        #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("in.png").path))
    }

    @Test func failedStepIsSkippedAndReported() async throws {
        // saveFile's "folder" is a regular file -> createDirectory fails
        let dir = tempDir()
        let blocker = try mkFile(dir, "not-a-dir")
        let file = try mkFile(dir)
        let fx = FakeEffects()
        let wf = Workflow(name: "w", takes: .screenshot, steps: [.saveFile(folder: blocker.path), .copyImage, .showToast])
        var events: [RunEvent] = []
        for await e in WorkflowRunner(effects: fx).run(file, through: wf, defaultFolder: tempDir()) { events.append(e) }
        guard case .failed(0, .saveFile, let msg) = events[1] else { Issue.record("expected failed event, got \(events)"); return }
        #expect(msg.hasPrefix("Save file: "))
        #expect(fx.order == ["copy", "toast"])
        guard case .done(let saved, let errors) = events.last else { Issue.record("no done"); return }
        #expect(saved.isEmpty)
        #expect(errors.count == 1)
    }

    @Test func overlappingCapturesRunIndependently() async throws {
        let dir = tempDir()
        let fileA = try mkFile(dir, "a.png"), fileB = try mkFile(dir, "b.png")
        let gate = Gate()
        let wf = Workflow(name: "w", takes: .screenshot, steps: [.copyImage])
        async let doneB: Void = {
            for await e in WorkflowRunner(effects: FakeEffects()).run(fileB, through: wf, defaultFolder: dir) { if case .done = e { return } }
        }()
        async let doneA: Void = {
            for await e in WorkflowRunner(effects: GatedEffects(gate)).run(fileA, through: wf, defaultFolder: dir) { if case .done = e { return } }
        }()
        try await Task.sleep(for: .milliseconds(100))
        await doneB // B completes while A's copy is still suspended
        await gate.open()
        await doneA
    }

    @Test func tempFileRuleWithInjectedClock() async throws {
        let clock = Clock()
        let capDir = tempDir(), saveDir = tempDir()
        let files = CaptureFiles(directory: capDir, now: { clock.t })
        let f = try files.newFile(ext: "png")
        try Data("png".utf8).write(to: f)
        var saved: [URL] = []
        let wf = Workflow(name: "w", takes: .screenshot, steps: [.saveFile(folder: saveDir.path)])
        for await e in WorkflowRunner(effects: FakeEffects()).run(f, through: wf, defaultFolder: saveDir) {
            if case .done(let s, _) = e { saved = s }
        }
        #expect(saved.count == 1)
        // the sweep checks real mtimes, so set them to match the injected clock
        let t0 = clock.t
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: f.path)
        let fresh = try files.newFile(ext: "png")
        try Data("x".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-24 * 3600)], ofItemAtPath: fresh.path)
        try files.sweep()
        #expect(!FileManager.default.fileExists(atPath: f.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: saved[0].path)) // outside the dir, never swept
    }

    // one undeletable entry doesn't stop the sweep; the failure still throws
    @Test func sweepKeepsGoingAfterAFailure() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = CaptureFiles(directory: dir, retention: 60, now: Date.init)
        let old = [FileAttributeKey.modificationDate: Date().addingTimeInterval(-3600)]
        let doomed = dir.appendingPathComponent("old.png")
        try Data("x".utf8).write(to: doomed)
        try FileManager.default.setAttributes(old, ofItemAtPath: doomed.path)
        let jail = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: jail, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: jail.appendingPathComponent("inner.png"))
        try FileManager.default.setAttributes(old, ofItemAtPath: jail.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: jail.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: jail.path) }
        #expect(throws: (any Error).self) { try files.sweep() }
        #expect(!FileManager.default.fileExists(atPath: doomed.path)) // other file still swept
        #expect(FileManager.default.fileExists(atPath: jail.appendingPathComponent("inner.png").path))
    }

    // Steps after a Save file work on the saved copy, not the temp capture
    @Test func effectsGetTheCurrentFile() async throws {
        let dir = tempDir(), saveDir = tempDir()
        let file = try mkFile(dir)
        let fx = FakeEffects()
        let wf = Workflow(name: "w", takes: .screenshot, steps: [.copyFile, .saveFile(folder: saveDir.path), .copyFile, .openIn(app: nil), .pin])
        let savedURL = saveDir.appendingPathComponent("in.png")
        for await _ in WorkflowRunner(effects: fx).run(file, through: wf, defaultFolder: tempDir()) {}
        #expect(fx.order == ["copyFile", "copyFile", "open", "pin"])
        #expect(fx.files == [file, savedURL, savedURL, savedURL])
    }

    // Proves Pin hands the effect the run's own Canvas package and current image, before and after Save file, and nil without a Canvas.
    @Test func pinGetsTheRunsCanvasAndCurrentImage() async throws {
        let dir = tempDir(), a = tempDir(), b = tempDir()
        let file = try mkFile(dir)
        let package = tempDir().appendingPathComponent("shot.wadjet")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let fx = FakeEffects()
        let wf = Workflow(name: "w", takes: .screenshot, steps: [
            .pin, .saveFile(folder: a.path), .pin, .saveFile(folder: b.path, format: .canvas), .pin])
        var last: RunEvent?
        for await e in WorkflowRunner(effects: fx).run(file, through: wf, defaultFolder: tempDir(), canvas: package) { last = e }
        #expect(fx.pinnedCanvases.map { $0?.path } == [package.path, package.path, package.path])
        let saved = a.appendingPathComponent("in.png")
        #expect(fx.files == [file, saved, saved])
        guard case .done(let doneSaved, let errors) = last else { Issue.record("no done, got \(last as Any)"); return }
        #expect(doneSaved.map(\.path) == [saved.path, b.appendingPathComponent("in.wadjet").path])
        #expect(errors.isEmpty)

        let fx2 = FakeEffects()
        let wf2 = Workflow(name: "w", takes: .screenshot, steps: [.pin])
        for await _ in WorkflowRunner(effects: fx2).run(file, through: wf2, defaultFolder: tempDir()) {}
        #expect(fx2.pinnedCanvases == [nil])
    }

    @Test func newStepsRoundTrip() throws {
        let steps: [Step] = [.copyFile, .openIn(app: "com.apple.Preview"), .openIn(app: nil), .pin]
        let back = try JSONDecoder().decode([Step].self, from: JSONEncoder().encode(steps))
        #expect(back == steps)
        // {"type":"openIn","app":"com.apple.Preview"} decodes; app omitted when nil
        #expect(try JSONDecoder().decode(Step.self, from: Data(#"{"type":"openIn","app":"com.apple.Preview"}"#.utf8)) == .openIn(app: "com.apple.Preview"))
        #expect(try JSONDecoder().decode(Step.self, from: Data(#"{"type":"openIn"}"#.utf8)) == .openIn(app: nil))
        let nilApp = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Step.openIn(app: nil))) as? [String: Any]
        #expect(nilApp?["app"] == nil)
    }

    @Test func mp4WorkflowWithPinFailsAtTheStepIndex() throws {
        let url = tempDir().appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"workflows":[{"name":"bad","takes":"mp4","steps":[{"type":"copyFile"},{"type":"pin"}]}]}"#.utf8).write(to: url)
        var errors: [ConfigError] = []
        _ = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        let err = try #require(errors.first)
        #expect(err.location == "workflows.0.steps.1")
        #expect(err.message.contains("Pin to screen only works on Screenshots"))
    }

    @Test func starterConfigRoundTrips() throws {
        let c = WadjetConfig()
        let back = try JSONDecoder().decode(WadjetConfig.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        #expect(back.workflows.first { $0.takes == .screenshot }?.steps == [.saveFile(folder: nil), .copyImage, .showToast])
        // {"type":"saveFile","folder":"~/x"} decodes
        let s = try JSONDecoder().decode(Step.self, from: Data(#"{"type":"saveFile","folder":"~/x"}"#.utf8))
        #expect(s == .saveFile(folder: "~/x"))
        // unknown type fails
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Step.self, from: Data(#"{"type":"beep"}"#.utf8)) }
    }

    @Test func mp4WorkflowWithCopyImageFailsThroughConfigStore() throws {
        let url = tempDir().appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"workflows":[{"name":"bad","takes":"mp4","steps":[{"type":"copyImage"}]}]}"#.utf8).write(to: url)
        var errors: [ConfigError] = []
        _ = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        let err = try #require(errors.first)
        #expect(err.location == "workflows.0.steps.0")
        #expect(err.message.contains("Copy image only works on Screenshots"))
    }

    @Test func newFileCollisionNaming() async throws {
        let clock = Clock()
        let dir = tempDir()
        let files = CaptureFiles(directory: dir, now: { clock.t })
        let f1 = try files.newFile(ext: "png")
        try Data("x".utf8).write(to: f1)
        let f2 = try files.newFile(ext: "png")
        try Data("x".utf8).write(to: f2)
        let f3 = try files.newFile(ext: "png")
        #expect(f1.lastPathComponent.hasPrefix("Wadjet 2023-11-14 at "))
        #expect(f1.pathExtension == "png")
        #expect(f2.lastPathComponent.contains(" 2.png"))
        #expect(f3.lastPathComponent.contains(" 3.png"))
        // a new second gets its own base name again
        clock.t = clock.t.addingTimeInterval(61)
        let f4 = try files.newFile(ext: "png")
        #expect(!f4.lastPathComponent.contains(" 3.png") && !f4.lastPathComponent.contains(" 2.png"))
    }

    @Test func expandingTildeUsesRealHome() {
        let u = expandingTilde("~/Pictures/Wadjet")
        #expect(u.path.hasPrefix("/Users/"))
        #expect(u.lastPathComponent == "Wadjet")
        #expect(!u.path.contains("Containers"))
    }
}
