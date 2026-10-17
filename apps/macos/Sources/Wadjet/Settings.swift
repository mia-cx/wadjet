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
    let mark = needsMark ? try? url.bookmarkData(options: .withSecurityScope) : nil
    return (String(path), mark)
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
        Section {
            Button("Reveal config.json") { AppDelegate.shared?.openConfigFile() }
        }
    }
}

// MARK: - Shortcuts

@MainActor struct ShortcutsPane: View {
    @State private var pending = false
    var body: some View {
        let cfg = AppState.shared.config.value
        Section("Shortcuts") {
            ForEach(Array(cfg.shortcuts.indices), id: \.self) { i in
                ShortcutRow(i: i)
            }
            if pending {
                HStack {
                    KeyboardShortcuts.Recorder(for: .init("settings.newShortcut")) { ks in
                        guard let ks, let keys = KeyCombo(keyCode: ks.carbonKeyCode, carbonModifiers: ks.carbonModifiers) else { return }
                        edit { $0.shortcuts.append(Shortcut(keys: keys, tool: .captureRegion)) }
                        KeyboardShortcuts.reset(.init("settings.newShortcut"))
                        pending = false
                    }
                    Spacer()
                    Button("Cancel") { pending = false }
                }
            } else {
                Button("Add Shortcut") { pending = true }
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
                    if let ks, let keys = KeyCombo(keyCode: ks.carbonKeyCode, carbonModifiers: ks.carbonModifiers) {
                        edit { guard i < $0.shortcuts.count else { return }; $0.shortcuts[i].keys = keys }
                    } else {
                        edit { guard i < $0.shortcuts.count else { return }; $0.shortcuts.remove(at: i) }
                    }
                }
                Picker("Tool", selection: cfgBinding(\.shortcuts).item(i).tool) {
                    ForEach(Tool.allCases, id: \.rawValue) { Text($0.title).tag($0.toolID) }
                }
                .labelsHidden()
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
            if tool?.kind == .rec {
                DisclosureGroup("Options") {
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
        })
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

@MainActor struct WorkflowsPane: View {
    @State private var sel: Int? = 0
    var body: some View {
        let cfg = AppState.shared.config.value
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $sel) {
                    ForEach(Array(cfg.workflows.indices), id: \.self) { i in
                        Text(cfg.workflows[i].name).tag(i)
                    }
                }
                HStack {
                    Menu("+") {
                        ForEach(CaptureKind.allCases, id: \.self) { k in
                            Button(k.rawValue.capitalized) {
                                edit { $0.workflows.append(Workflow(name: "New \(k.rawValue.capitalized) Workflow", takes: k, steps: [.showToast])) }
                            }
                        }
                    }
                    Button("−") {
                        guard let sel else { return }
                        edit { $0.workflows.remove(at: sel) }
                    }
                    .disabled(sel.map { isDefault($0) } ?? true)
                    Spacer()
                }
                .padding(6)
            }
            .frame(minWidth: 160, maxWidth: 200)
            if let sel, sel < cfg.workflows.count {
                WorkflowDetail(i: sel)
            } else {
                Text("Select a Workflow").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    func isDefault(_ i: Int) -> Bool {
        let cfg = AppState.shared.config.value
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
        return AnyView(Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit { guard name != wf.name else { return }; edit { $0.renameWorkflow(from: wf.name, to: name) } }
                    .onAppear { name = wf.name }
                Text(wf.takes.rawValue.capitalized).foregroundStyle(.secondary)
            }
            Section("Steps") {
                List {
                    ForEach(Array(wf.steps.indices), id: \.self) { s in
                        StepRow(wf: i, step: s)
                    }
                    .onMove { from, to in edit { $0.workflows[i].steps.move(fromOffsets: from, toOffset: to) } }
                    .onDelete { at in edit { $0.workflows[i].steps.remove(atOffsets: at) } }
                }
                .frame(minHeight: 140)
                Menu("Add Step") {
                    ForEach(Array(Step.allowed(for: wf.takes).indices), id: \.self) { s in
                        Button(Step.allowed(for: wf.takes)[s].title) {
                            edit { $0.workflows[i].steps.append(Step.allowed(for: wf.takes)[s]) }
                        }
                    }
                }
            }
            if wf.takes == .screenshot {
                defaultPicker("Default Screenshot Workflow", \.defaultWorkflows.screenshot)
            } else {
                defaultPicker("Default Recording Workflow", \.defaultWorkflows.recording)
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
            case .saveFile(let folder):
                HStack {
                    Text(folder ?? "Default folder").font(.caption).foregroundStyle(.secondary)
                    Button("Choose…") {
                        guard let pick = pickFolder() else { return }
                        edit { guard step < $0.workflows[wf].steps.count else { return }
                            $0.workflows[wf].steps[step] = .saveFile(folder: pick.path)
                            if let mark = pick.bookmark { $0.bookmarks[pick.path] = mark } }
                    }.font(.caption)
                    if folder != nil {
                        Button("Use Default") { edit { $0.workflows[wf].steps[step] = .saveFile(folder: nil) } }.font(.caption)
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
