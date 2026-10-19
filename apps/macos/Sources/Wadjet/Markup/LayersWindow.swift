import AppKit
import SwiftUI
import WadjetKit

/// The Layers window's panel: independent of the overlay, so the Editor can
/// host the same list later. Floating and non-activating like the Tool menus.
final class LayersPanel: NSPanel {
    init(content: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Layers"
        isFloatingPanel = true
        // above the Markup panels at .screenSaver, level with the toolbar;
        // Tool menus sit higher
        level = .screenSaver + 1
        hidesOnDeactivate = false // utility panels hide on deactivate — Markup runs over other apps
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        minSize = NSSize(width: 200, height: 160)
        contentView = NSHostingView(rootView: content)
        if !setFrameUsingName("Layers"), let vf = NSScreen.main?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: vf.maxX - frame.width - 20, y: vf.maxY - 20))
        }
        setFrameAutosaveName("Layers")
    }
}

/// the Layers list, value-driven: rows are front first, the opposite of the
/// LayerStack's back-to-front order
struct LayersView: View {
    let annotations: [Annotation]                 // back to front, as LayerStack holds them
    @Binding var selection: Annotation.ID?
    let move: (Annotation.ID, Int) -> Void        // to a back-to-front index
    let update: (Annotation) -> Void

    var rows: [Annotation] { annotations.reversed() } // front first

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView("No Annotations", systemImage: "square.3.layers.3d")
        } else {
            List(selection: $selection) {
                ForEach(rows) { a in
                    LayerRow(annotation: a, update: update)
                        .tag(a.id)
                        .selectionDisabled(a.hidden || a.locked)
                }
                .onMove { from, to in
                    guard let i = from.first else { return }
                    var ids = rows.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    guard let f = ids.firstIndex(of: rows[i].id) else { return }
                    move(rows[i].id, rows.count - 1 - f)
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 32)
        }
    }
}

/// one row: thumbnail, kind name, and eye/lock toggles that reserve their
/// space and fade in on hover (or stay lit while on)
struct LayerRow: View {
    let annotation: Annotation
    let update: (Annotation) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            LayerThumbnail(annotation: annotation)
                .frame(width: 28, height: 28)
                .opacity(annotation.hidden ? 0.45 : 1)
            Text(annotation.kind.title)
                .lineLimit(1)
                .opacity(annotation.hidden ? 0.45 : 1)
            Spacer(minLength: 4)
            Button {
                var a = annotation; a.hidden.toggle(); update(a)
            } label: {
                Label(annotation.hidden ? "Show" : "Hide",
                      systemImage: annotation.hidden ? "eye.slash" : "eye")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 18)
            .help(annotation.hidden ? "Show" : "Hide")
            .opacity(hovering || annotation.hidden ? 1 : 0)
            Button {
                var a = annotation; a.locked.toggle(); update(a)
            } label: {
                Label(annotation.locked ? "Unlock" : "Lock",
                      systemImage: annotation.locked ? "lock.fill" : "lock.open")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 18)
            .help(annotation.locked ? "Unlock" : "Lock")
            .opacity(hovering || annotation.locked ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}

/// the Annotation's path scaled into a small swatch — geometry is y-up
/// screen points, the Canvas is y-down, so the fit flips y
struct LayerThumbnail: View {
    let annotation: Annotation

    var body: some View {
        Canvas { ctx, size in
            let path = PathGeometry.path(for: annotation)
            let b = path.boundingBoxOfPath
            let side = min(size.width, size.height)
            let s = (side - 10) / max(b.width, b.height, 1)
            let t = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                .scaledBy(x: s, y: -s)
                .translatedBy(x: -b.midX, y: -b.midY)
            // fill and stroke as MarkupView draws them: fillColour for the
            // inside (a Black out's opaque black), strokeColour for the outline,
            // and whole-Annotation opacity except on Black out, which stays opaque
            if case .censor = annotation.kind {} else { ctx.opacity = annotation.style.opacity }
            func colour(_ c: RGBAColour) -> Color {
                Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
            }
            let p = Path(path).applying(t)
            if let f = annotation.fillColour { ctx.fill(p, with: .color(colour(f))) }
            if let c = annotation.strokeColour {
                ctx.stroke(p, with: .color(colour(c)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
    }
}

extension AnnotationKind {
    /// the Layers row's name
    var title: String {
        switch self {
        case .line: "Line"
        case .censor: "Black out"
        case let .shape(kind, _): kind.variant.rawValue.capitalized
        }
    }
}

/// the Markup glue: shows the panel while it's wanted and the toolbar is up
@MainActor
final class LayersWindow {
    static let shared = LayersWindow()
    private var wanted = false
    private var panel: LayersPanel?
    private init() {}
    var windowNumber: Int? { panel?.windowNumber }

    func toggle() {
        wanted.toggle()
        sync()
        AppLog.line("layers: \(wanted ? "shown" : "hidden")")
    }

    /// visible while wanted, the toolbar is open, and a Markup Tool (or none)
    /// is active; created lazily, hidden with orderOut so it keeps its frame
    func sync() {
        let s = AppState.shared
        guard wanted && s.toolbarOpen && (s.tool?.kind ?? .markup) == .markup else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            let p = LayersPanel(content: MarkupLayersList())
            // the close button ends the want; orderOut doesn't post this
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: p, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.wanted = false }
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }
}

/// reads the shared controller into the value-driven LayersView
private struct MarkupLayersList: View {
    var body: some View {
        let c = MarkupController.shared
        LayersView(annotations: c.stack.annotations,
                   selection: Binding(get: { c.selection }, set: { c.select($0) }),
                   move: c.moveLayer,
                   update: c.update)
    }
}
