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
    func copyImage(_ file: URL, run: UUID) async throws { order.append("copy") }
    func showToast(_ file: URL, run: UUID) async throws { order.append("toast") }
}

// injectable clock for CaptureFiles' `now:` — a @Sendable closure can't hold a var
private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_700_000_000) }

// a Step whose copy suspends until `open()` — proves run B isn't held back
private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func open() { waiter?.resume() }
}
private final class GatedEffects: WorkflowEffects, @unchecked Sendable {
    let gate: Gate
    init(_ g: Gate) { gate = g }
    func copyImage(_ file: URL, run: UUID) async throws { await gate.wait() }
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
        #expect(err.location?.hasPrefix("workflows") == true)
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
