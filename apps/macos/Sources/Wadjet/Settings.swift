import SwiftUI
import AppKit
import KeyboardShortcuts
import WadjetKit

// MARK: - Settings window

/// Everything edits AppState.shared.config directly, so a hand edit to
/// config.json shows up live in the open window.
enum SettingsPanes: String, CaseIterable {
    case general = "General", shortcuts = "Shortcuts", workflows = "Workflows", tools = "Tools"
    var symbol: String {
        switch self {
        case .general: "gear"
        case .shortcuts: "keyboard"
        case .workflows: "rectangle.stack"
        case .tools: "wrench"
        }
    }
}

@MainActor private func edit(_ change: (inout WadjetConfig) -> Void) {
    AppState.shared.config.update(change)
}

@MainActor private func cfgBinding<T>(_ key: WritableKeyPath<WadjetConfig, T>) -> Binding<T> {
    Binding(get: { AppState.shared.config.value[keyPath: key] },
            set: { v in AppState.shared.config.update { $0[keyPath: key] = v } })
}

@MainActor struct SettingsView: View {
    @State private var pane = SettingsPanes.general
    var body: some View {
        NavigationSplitView {
            List(SettingsPanes.allCases, id: \.self, selection: $pane) { p in
                Label(p.rawValue, systemImage: p.symbol)
            }
            .navigationSplitViewColumnWidth(150)
        } detail: {
            Form {
                switch pane {
                case .general: GeneralPane()
                case .shortcuts: ShortcutsPane()
                case .workflows: WorkflowsPane()
                case .tools: ToolsPane()
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 420)
        }
    }
}

// MARK: pickers

/// Choose a folder; writes `~/…` under the real home and a security-scoped
/// bookmark when the folder is outside the sandbox's Pictures/Movies grants.
@MainActor private func pickFolder() -> (path: String, bookmark: Data?)? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    let home = expandingTilde("~").path // real home, not the sandbox container
    let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    let granted = [home + "/Pictures", home + "/Movies"]
    let needsMark = !granted.contains { url.path.hasPrefix($0 + "/") || url.path == $0 }
    // without its bookmark the folder only works until relaunch — don't take it
    if needsMark {
        guard let mark = try? url.bookmarkData(options: .withSecurityScope) else {
            AppLog.line("settings: couldn't make a folder bookmark for \(url.path)")
            return nil
        }
        return (String(path), mark)
    }
    return (String(path), nil)
}

@MainActor private func pickApp() -> String? {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return Bundle(url: url)?.bundleIdentifier
}

// MARK: - General

@MainActor private struct FolderRow: View {
    let key: WritableKeyPath<WadjetConfig.Folders, String>
    var body: some View {
        let path = AppState.shared.config.value.folders[keyPath: key]
        HStack {
            Text(path)
            Spacer()
            Button("Choose…") {
                guard let pick = pickFolder() else { return }
                edit {
                    $0.folders[keyPath: key] = pick.path
                    if let mark = pick.bookmark { $0.bookmarks[pick.path] = mark }
                }
            }
        }
    }
}

@MainActor struct GeneralPane: View {
    var body: some View {
        Section("Save folders") {
            LabeledContent("Screenshots") { FolderRow(key: \.screenshots) }
            LabeledContent("Recordings") { FolderRow(key: \.recordings) }
        }
        Section("Capture") {
            Toggle("Freeze the screen while selecting", isOn: cfgBinding(\.capture.freeze))
            Picker("Freeze while recording", selection: cfgBinding(\.capture.freezeWhileRecording)) {
                Text("Default").tag(Bool?.none); Text("On").tag(Bool?(true)); Text("Off").tag(Bool?(false))
            }
            Toggle("Capture the cursor", isOn: cfgBinding(\.capture.cursor))
        }
        CanvasRetentionRows()
        Section {
            Button("Reveal config.json") {
                NSWorkspace.shared.activateFileViewerSelecting([AppState.shared.config.file])
            }
        }
    }
}

// MARK: - Shortcuts

/// every Tool listed like OBS's hotkey settings; Shortcuts get added under
/// their Tool with the + — several per Tool stay possible, each with its own
/// Workflow and options
@MainActor struct ShortcutsPane: View {
    @State private var pendingTool: Tool? = nil // the block currently holding a new-Shortcut recorder
    var body: some View {
        Section("Screenshots") { ForEach(Tool.allCases.filter { $0.kind == .shot }, id: \.rawValue) { ToolShortcuts(tool: $0, pendingTool: $pendingTool) } }
        Section("Recordings") { ForEach(Tool.allCases.filter { $0.kind == .rec }, id: \.rawValue) { ToolShortcuts(tool: $0, pendingTool: $pendingTool) } }
        Section("Utilities") { ForEach(Tool.allCases.filter { $0.kind == .util }, id: \.rawValue) { ToolShortcuts(tool: $0, pendingTool: $pendingTool) } }
        Section("Markup") { ForEach(Tool.allCases.filter { $0.kind == .markup && !$0.isAction }, id: \.rawValue) { ToolShortcuts(tool: $0, pendingTool: $pendingTool) } }
    }
}

/// one Tool's header plus its Shortcuts; + starts recording a new Shortcut
/// for this Tool
@MainActor struct ToolShortcuts: View {
    let tool: Tool
    @Binding var pendingTool: Tool?
    var body: some View {
        let cfg = AppState.shared.config.value
        let mine = cfg.shortcuts.indices.filter { cfg.shortcuts[$0].tool == tool.toolID }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(tool.title, systemImage: tool.symbol)
                Spacer()
                ForEach(MarkupToolKey.all.filter { $0.markupTool == tool }, id: \.character) { key in
                    HStack(spacing: 4) {
                        if let variant = key.variant { Text(variant.title).font(.caption).foregroundStyle(.secondary) }
                        Text(String(key.character).uppercased())
                            .font(.caption.monospaced())
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: .rect(cornerRadius: 4))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Key \(String(key.character).uppercased())\(key.variant.map { ", \($0.title)" } ?? "")")
                }
                if tool.toolID != nil {
                    Button { pendingTool = tool } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Add Shortcut")
                        .accessibilityLabel("Add Shortcut for \(tool.title)")
                }
            }
            ForEach(mine, id: \.self) { ShortcutRow(i: $0) }
            if pendingTool == tool {
                HStack {
                    KeyboardShortcuts.Recorder(for: .init("settings.newShortcut")) { ks in
                        guard let ks, let id = tool.toolID else { return }
                        guard let keys = KeyCombo(keyCode: ks.carbonKeyCode, carbonModifiers: ks.carbonModifiers) else {
                            AppLog.line("settings: recorded key isn't a config KeyCombo — try another")
                            KeyboardShortcuts.reset(.init("settings.newShortcut"))
                            return
                        }
                        edit { $0.shortcuts.append(Shortcut(keys: keys, tool: id)) }
                        KeyboardShortcuts.reset(.init("settings.newShortcut"))
                        pendingTool = nil
                    }
                    Spacer()
                    Button("Cancel") { pendingTool = nil }
                }
                .padding(.leading, 28)
            }
        }
    }
}

@MainActor struct ShortcutRow: View {
    let i: Int
    var body: some View {
        let cfg = AppState.shared.config.value
        guard i < cfg.shortcuts.count else { return AnyView(EmptyView()) }
        let sc = cfg.shortcuts[i]
        let tool = Tool(rawValue: sc.tool.rawValue)
        let workflows = tool.map { AppState.shared.workflows(for: $0) } ?? []
        return AnyView(VStack(alignment: .leading, spacing: 6) {
            HStack {
                KeyboardShortcuts.Recorder(for: .init("shortcut.\(i)")) { ks in
                    if ks == nil {
                        edit { guard i < $0.shortcuts.count else { return }; $0.shortcuts.remove(at: i) }
                    } else if let keys = KeyCombo(keyCode: ks!.carbonKeyCode, carbonModifiers: ks!.carbonModifiers) {
                        edit { guard i < $0.shortcuts.count else { return }; $0.shortcuts[i].keys = keys }
                    } else {
                        AppLog.line("shortcut \(i): recorded key isn't a config KeyCombo — keeping the old one")
                    }
                }
                Spacer()
                Button { edit { guard i < $0.shortcuts.count else { return }; $0.shortcuts.remove(at: i) } }
                    label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if !workflows.isEmpty {
                Picker("Workflow", selection: Binding(get: { sc.workflow ?? "" }, set: { v in
                    edit { guard i < $0.shortcuts.count else { return }; $0.shortcuts[i].workflow = v.isEmpty ? nil : v }
                })) {
                    Text("Default").tag("")
                    ForEach(workflows, id: \.self) { Text($0).tag($0) }
                }
            }
            if tool?.confirmOptional == true {
                Toggle(tool!.kind == .rec ? "Confirm before recording" : "Confirm before capture",
                       isOn: Binding(get: { sc.options.confirm ?? true }, set: { v in
                           edit { guard i < $0.shortcuts.count else { return }
                               // on is the default — write nil so the file stays tidy
                               $0.shortcuts[i].options.confirm = v ? nil : false
                           }
                       }))
            }
            if let tool, tool.kind != .util {
                DisclosureGroup("Options") {
                    optionRow("Freeze the screen", \.freeze)
                    if tool.kind != .rec { // a Record Shortcut during a Recording only stops it
                        optionRow("Freeze while recording", \.freezeWhileRecording)
                    }
                    if tool.kind == .rec {
                        Picker("Countdown", selection: opt(\.countdown, i: i)) {
                            Text("Default").tag(-1); Text("Off").tag(0)
                            Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10)
                        }
                        optionRow("System audio", \.systemAudio)
                        optionRow("Microphone", \.microphone)
                        optionRow("Cursor", \.cursor)
                        optionRow("Click circles", \.clickCircles)
                    }
                }
            }
        }
        .padding(.leading, 28))
    }
    // 0=Default(nil) 1=On 2=Off
    func opt(_ key: WritableKeyPath<ShortcutOptions, Int?>, i: Int) -> Binding<Int> {
        Binding(get: { AppState.shared.config.value.shortcuts[i].options[keyPath: key] ?? -1 },
                set: { v in edit { guard i < $0.shortcuts.count else { return }; $0.shortcuts[i].options[keyPath: key] = v == -1 ? nil : v } })
    }
    func optionRow(_ label: String, _ key: WritableKeyPath<ShortcutOptions, Bool?>) -> some View {
        Picker(label, selection: Binding(get: {
            AppState.shared.config.value.shortcuts[i].options[keyPath: key].map { $0 ? 1 : 2 } ?? 0
        }, set: { v in
            edit { guard i < $0.shortcuts.count else { return }; $0.shortcuts[i].options[keyPath: key] = v == 1 ? true : v == 2 ? false : nil }
        })) {
            Text("Default").tag(0); Text("On").tag(1); Text("Off").tag(2)
        }
    }
}

private extension Binding where Value == [Shortcut] {
    func item(_ i: Int) -> Binding<Shortcut> {
        Binding<Shortcut>(get: { self.wrappedValue[i] }, set: { self.wrappedValue[i] = $0 })
    }
}

// MARK: - Workflows

/// "Base", "Base 2", … — Workflow names are their identity, so they stay unique.
private func uniqueName(_ base: String, in cfg: WadjetConfig, skipping: Int? = nil) -> String {
    let taken = Set(cfg.workflows.indices.filter { $0 != skipping }.map { cfg.workflows[$0].name })
    guard taken.contains(base) else { return base }
    var n = 2
    while taken.contains("\(base) \(n)") { n += 1 }
    return "\(base) \(n)"
}

@MainActor struct WorkflowsPane: View {
    @State private var sel = 0
    var body: some View {
        let cfg = AppState.shared.config.value
        // config.json can shrink under us — clamp the selection on read
        let i = cfg.workflows.isEmpty ? 0 : min(sel, cfg.workflows.count - 1)
        Section {
            HStack {
                Picker("Workflow", selection: $sel) {
                    ForEach(Array(cfg.workflows.indices), id: \.self) { i in
                        Text(cfg.workflows[i].name).tag(i)
                    }
                }
                Menu("+") {
                    ForEach(CaptureKind.allCases, id: \.self) { k in
                        Button(k.title) {
                            edit {
                                $0.workflows.append(Workflow(name: uniqueName("New \(k.title) Workflow", in: $0), takes: k, steps: [.showToast]))
                                sel = $0.workflows.count - 1
                            }
                        }
                    }
                }
                Button("−") {
                    guard i < cfg.workflows.count else { return }
                    edit {
                        let name = $0.workflows[i].name
                        $0.workflows.remove(at: i)
                        for s in $0.shortcuts.indices where $0.shortcuts[s].workflow == name {
                            $0.shortcuts[s].workflow = nil // don't leave a dangling reference
                        }
                    }
                    sel = max(0, i - 1)
                }
                .disabled(isDefault(i))
            }
        }
        if !cfg.workflows.isEmpty {
            WorkflowDetail(i: i).id(cfg.workflows[i].name) // rebuild when the picked Workflow or its name changes
        }
    }
    func isDefault(_ i: Int) -> Bool {
        let cfg = AppState.shared.config.value
        guard i < cfg.workflows.count else { return true }
        let n = cfg.workflows[i].name
        return cfg.defaultWorkflows.screenshot == n || cfg.defaultWorkflows.recording == n
    }
}

@MainActor struct WorkflowDetail: View {
    let i: Int
    @State private var name = ""
    var body: some View {
        let cfg = AppState.shared.config.value
        guard i < cfg.workflows.count else { return AnyView(EmptyView()) }
        let wf = cfg.workflows[i]
        return AnyView(Group {
            Section {
                TextField("Name", text: $name)
                    .onSubmit {
                        guard name != wf.name else { return }
                        edit { $0.renameWorkflow(from: wf.name, to: uniqueName(name, in: $0, skipping: i)) }
                    }
                    .onAppear { name = wf.name }
                LabeledContent("Takes", value: wf.takes.title)
            }
            // .onMove/.onDelete don't work in a macOS grouped Form — explicit
            // up/down/remove buttons instead
            Section("Steps") {
                ForEach(Array(wf.steps.indices), id: \.self) { s in
                    HStack {
                        StepRow(wf: i, step: s)
                        Spacer()
                        Group {
                        Button { edit { guard s > 0, i < $0.workflows.count else { return }
                            $0.workflows[i].steps.swapAt(s, s - 1) } }
                            label: { Image(systemName: "arrow.up") }
                            .accessibilityLabel("Move Up")
                            .disabled(s == 0)
                        Button { edit { guard i < $0.workflows.count, s + 1 < $0.workflows[i].steps.count else { return }
                            $0.workflows[i].steps.swapAt(s, s + 1) } }
                            label: { Image(systemName: "arrow.down") }
                            .accessibilityLabel("Move Down")
                            .disabled(s == wf.steps.count - 1)
                        Button { edit { guard i < $0.workflows.count, s < $0.workflows[i].steps.count else { return }
                            $0.workflows[i].steps.remove(at: s) } }
                            label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove Step")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                Menu("Add Step") {
                    ForEach(Array(Step.allowed(for: wf.takes).indices), id: \.self) { s in
                        Button(Step.allowed(for: wf.takes)[s].title) {
                            edit { $0.workflows[i].steps.append(Step.allowed(for: wf.takes)[s]) }
                        }
                    }
                }
            }
            Section {
                if wf.takes == .screenshot {
                    defaultPicker("Default Screenshot Workflow", \.defaultWorkflows.screenshot)
                } else {
                    defaultPicker("Default Recording Workflow", \.defaultWorkflows.recording)
                }
            }
        })
    }
    func defaultPicker(_ label: String, _ key: WritableKeyPath<WadjetConfig, String>) -> some View {
        let cfg = AppState.shared.config.value
        let kind = AppState.shared.config.value.workflows[i].takes
        return Picker(label, selection: cfgBinding(key)) {
            ForEach(cfg.workflows.filter { $0.takes == kind || kind.isRecording && $0.takes.isRecording }.map(\.name), id: \.self) {
                Text($0).tag($0)
            }
        }
    }
}

@MainActor struct StepRow: View {
    let wf: Int
    let step: Int
    var body: some View {
        let cfg = AppState.shared.config.value
        guard wf < cfg.workflows.count, step < cfg.workflows[wf].steps.count else { return AnyView(EmptyView()) }
        let st = cfg.workflows[wf].steps[step]
        return AnyView(VStack(alignment: .leading) {
            Text(st.title)
            switch st {
            case .saveFile(let folder, let format):
                if cfg.workflows[wf].takes == .screenshot {
                    SaveFileFormatPicker(workflow: wf, step: step, folder: folder, format: format)
                }
                HStack {
                    Text(folder ?? "Default folder").font(.caption).foregroundStyle(.secondary)
                    Button("Choose…") {
                        guard let pick = pickFolder() else { return }
                        edit { guard step < $0.workflows[wf].steps.count else { return }
                            $0.workflows[wf].steps[step] = .saveFile(folder: pick.path, format: format)
                            if let mark = pick.bookmark { $0.bookmarks[pick.path] = mark } }
                    }.font(.caption)
                    if folder != nil {
                        Button("Use Default") { edit { $0.workflows[wf].steps[step] = .saveFile(folder: nil, format: format) } }.font(.caption)
                    }
                }
            case .openIn(let app):
                HStack {
                    Text(app ?? "Default app").font(.caption).foregroundStyle(.secondary)
                    Button("Choose…") {
                        guard let id = pickApp() else { return }
                        edit { $0.workflows[wf].steps[step] = .openIn(app: id) }
                    }.font(.caption)
                    if app != nil {
                        Button("Use Default") { edit { $0.workflows[wf].steps[step] = .openIn(app: nil) } }.font(.caption)
                    }
                }
            default: EmptyView()
            }
        })
    }
}

// MARK: - Tools

@MainActor struct ToolsPane: View {
    var body: some View {
        Section("Pick Colour") {
            Picker("Format", selection: cfgBinding(\.tools.pickColour.format)) {
                ForEach(ColourFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
        Section("Measure") {
            Picker("Mode", selection: cfgBinding(\.tools.measure.mode)) {
                ForEach(MeasureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
    }
}
