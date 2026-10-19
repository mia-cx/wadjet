import AppKit
import SwiftUI
import WadjetKit

extension OverlayController {
    /// headroom above the menu so its scale-in never clips; the monitor treats
    /// that strip as outside the menu body
    static let menuHeadroom: CGFloat = 40

    /// the menu panel's height for `t` with its body capped at `maxBody`
    /// points; sets AppState.menuScrollHeight when the content is taller, so
    /// the body scrolls instead of running off the display
    func cappedMenuHeight(_ t: Tool, maxBody: CGFloat) -> CGFloat {
        AppState.shared.menuScrollHeight = nil
        let natural = NSHostingView(rootView: ToolMenuView(tool: t, ctrl: self)
            .padding(.top, Self.menuHeadroom)
            .frame(maxHeight: .infinity, alignment: .top)).fittingSize.height
        let body = natural - Self.menuHeadroom
        AppState.shared.menuScrollHeight = body > maxBody ? maxBody : nil
        return min(body, maxBody) + Self.menuHeadroom
    }

    /// resizes the open menu's panel to its content, keeping its top edge —
    /// for a menu whose content grows (the colour wheel)
    func fitMenu() {
        guard let t = AppState.shared.openMenu, let p = menuPanel else { return }
        let maxBody = (p.frame.maxY - Self.menuHeadroom) - ((p.screen ?? NSScreen.main!).frame.minY + 8)
        let h = cappedMenuHeight(t, maxBody: maxBody)
        var f = p.frame
        f.origin.y = f.maxY - h // keep the top edge: the menu grows downward
        f.size.height = h
        p.setFrame(f, display: true)
    }
}

/// The Markup Tool menu: a colour row (well, recent swatches, eyedropper),
/// the expandable hue wheel, and stroke weight / opacity sliders — ToolMenuView
/// metrics, no sections.
struct MarkupStyleControls: View {
    let tool: Tool
    let ctrl: OverlayController
    var styles: MarkupStyles { .shared }
    @State var width: Double = 0
    @State var opacity: Double = 0
    @State var smoothing: Double = DrawVariant.defaultSmoothing
    /// a slider is mid-drag — re-seeding then would fight the user's thumb
    @State var editing = false

    var style: AnnotationStyle { styles.style(for: tool) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkupColourRow(tool: tool, target: .stroke, ctrl: ctrl)
            divider()
            // a counter has no stroke — its Size slider replaces this — and
            // Text sets its own format controls instead of a stroke weight
            if tool != .counter && !styles.editsText(tool) {
                MenuSliderRow(icon: "lineweight", label: "Stroke weight", text: "\(Int(width)) pt",
                              value: $width, range: 1...24, step: 1, editing: $editing) {
                    styles.restyle(tool) { $0.width = CGFloat(width) }
                }
            }
            MenuSliderRow(icon: "circle.lefthalf.filled", label: "Opacity",
                          text: "\(Int((opacity * 100).rounded()))%",
                          value: $opacity, range: 0.1...1, step: 0.05, editing: $editing) {
                styles.restyle(tool) { $0.opacity = opacity }
            }
            if brushControls {
                MenuSliderRow(icon: "scribble.variable", label: "Smoothing",
                              text: "\(Int((smoothing * 100).rounded()))%",
                              value: $smoothing, range: 0...1, step: 0.05, editing: $editing) {
                    styles.setSmoothing(smoothing, for: tool)
                }
            }
            if lineControls {
                divider()
                endRow(side: "Start", atStart: true, current: style.tail) { end in
                    styles.restyle(tool) { $0.tail = end }
                }
                endRow(side: "End", atStart: false, current: style.head) { end in
                    styles.restyle(tool) { $0.head = end }
                }
                HStack(spacing: 0) {
                    ForEach(LineDash.allCases, id: \.self) { d in
                        MenuCell(pinned: d == style.dash) {
                            styles.restyle(tool) { $0.dash = d }
                        } content: {
                            lineGlyph(dash: d)
                        }
                        .accessibilityLabel("Dash: \(d.title)")
                        .accessibilityAddTraits(d == style.dash ? .isSelected : [])
                    }
                }
                .frame(minHeight: 40)
            }
            if penFillControls { ShapePaintControls(tool: tool, ctrl: ctrl) }
        }
        .onAppear {
            styles.refreshSwatches()
            width = Double(style.width)
            opacity = style.opacity
            smoothing = styles.smoothing(for: tool)
        }
        // the selection can change under an open menu — follow it unless a
        // slider is mid-drag
        .onChange(of: style) { _, st in
            guard !editing else { return }
            width = Double(st.width)
            opacity = st.opacity
            smoothing = styles.smoothing(for: tool)
        }
    }

    func divider() -> some View {
        Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
            .padding(.horizontal, 20).padding(.vertical, 3)
    }

    // MARK: line ends and dashes — drawn by WadjetKit so glyphs match the canvas

    /// the end/dash rows show while Draw is armed (both variants) or a
    /// stroked open shape — a Line or an open Pen path — is selected
    var lineControls: Bool {
        if tool == .draw { return true }
        guard let k = MarkupController.active.selected?.kind else { return false }
        switch k {
        case .line: return true
        case .path: return !k.isClosed
        default: return false
        }
    }

    /// the Smoothing slider shows while a brush variant is armed or a Brush
    /// stroke (a fitted path that kept its samples) is selected
    var brushControls: Bool {
        if let a = MarkupController.active.selected, case let .path(d) = a.kind, d.rawPoints != nil { return true }
        return tool == .draw && styles.drawVariant.isBrush
    }

    /// the Fill toggle shows while the Pen variant is armed or a closed path
    /// is selected — only closed paths can fill
    var penFillControls: Bool {
        if tool == .draw && styles.drawVariant == .pen { return true }
        guard let k = MarkupController.active.selected?.kind, k.isClosed else { return false }
        return true
    }

    /// a row of the five LineEnds; `atStart` decorates the sample line's left tip
    func endRow(side: String, atStart: Bool, current: LineEnd,
                pick: @escaping (LineEnd) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(LineEnd.allCases, id: \.self) { end in
                MenuCell(pinned: end == current) { pick(end) } content: {
                    lineGlyph(head: atStart ? .none : end, tail: atStart ? end : .none)
                }
                .accessibilityLabel("\(side): \(end.title)")
                .accessibilityAddTraits(end == current ? .isSelected : [])
            }
        }
        .frame(minHeight: 40)
    }

    /// a ~26 pt sample Line rendered by PathGeometry itself — what the glyph
    /// shows is what the canvas draws
    func lineGlyph(head: LineEnd = .none, tail: LineEnd = .none, dash: LineDash = .solid) -> some View {
        let w = 2.0
        let a = Annotation(kind: .line(start: CGPoint(x: 0, y: 10), end: CGPoint(x: 26, y: 10)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 1, blue: 1, alpha: 1),
                                                  width: w, head: head, tail: tail, dash: dash))
        let d = PathGeometry.drawing(for: a)
        return ZStack {
            Path(d.stroke)
                .stroke(.white, style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round,
                                                   dash: dash.pattern(width: w) ?? []))
            Path(d.ends).fill(.white)
        }
        .frame(width: 26, height: 20)
    }
}

/// a colour row (well, six swatches, eyedropper) with its expandable hue
/// wheel, editing `target` — Draw's stroke or a shape's fill
struct MarkupColourRow: View {
    let tool: Tool
    let target: ColourTarget
    let ctrl: OverlayController
    @ObservedObject var s = AppState.shared
    var styles: MarkupStyles { .shared }

    var colour: RGBAColour { styles.colour(for: tool, target: target) }
    var open: Bool { styles.wheel == target }
    /// VoiceOver names the non-stroke rows' controls "Fill …" / "Border …"
    var voiceOver: String {
        switch target { case .fill: "Fill "; case .border: "Border "; case .stroke: "" }
    }

    var body: some View {
        colourRow
        if open {
            ColourWheelView(tool: tool, target: target)
                .frame(width: 200, height: 200)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .scale(0.95, anchor: .top)))
        }
    }

    // MARK: colour row — 8 cells: well, six swatches, eyedropper

    var colourRow: some View {
        HStack(spacing: 0) {
            MenuCell(pinned: open, action: toggleWheel) {
                // the colour well: current colour inside a rainbow ring
                Circle()
                    .stroke(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                                            center: .center), lineWidth: 2.5)
                    .frame(width: 30.5, height: 30.5)
                    .overlay {
                        Circle().fill(Color(red: colour.red, green: colour.green, blue: colour.blue))
                            .frame(width: 24, height: 24)
                    }
            }
            .accessibilityLabel("\(voiceOver)Colour wheel")
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(open ? "On" : "Off")

            ForEach(0..<MarkupStyles.swatchCount, id: \.self) { i in
                if i < styles.swatches.count {
                    let c = styles.swatches[i]
                    MenuCell {
                        styles.useColour(c, for: tool, target: target)
                        s.openMenu = nil; ctrl.syncMenu()
                    } content: {
                        Circle().fill(Color(red: c.red, green: c.green, blue: c.blue))
                            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5)) // black must read on dark glass
                            .overlay { // the current colour wears a ring
                                if c.hex == colour.hex {
                                    Circle().stroke(.white, lineWidth: 2).padding(-2)
                                }
                            }
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel("\(voiceOver)Colour \(c.hex)")
                    .accessibilityAddTraits(c.hex == colour.hex ? .isSelected : [])
                } else {
                    Color.clear.frame(maxWidth: .infinity, minHeight: 40)
                }
            }

            MenuCell { styles.beginEyedropper(for: tool, target: target) } content: {
                Image(systemName: "eyedropper").font(.system(size: 15)).foregroundStyle(.white)
            }
            .accessibilityLabel("Pick \(voiceOver.lowercased())colour from screen")
        }
        .frame(minHeight: 40)
    }

    func toggleWheel() {
        if open {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                styles.wheel = nil
            } completion: {
                ctrl.fitMenu() // the panel shrinks once the wheel has animated out
            }
        } else {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                styles.wheel = target
            }
            ctrl.fitMenu() // grow at once: the content springs in inside
        }
    }
}

/// MenuRow metrics — leading 22 pt icon, trailing value — but the row
/// slides instead of picking, and only commits on release. `editing` holds
/// the drag state so callers don't re-seed `value` mid-drag.
struct MenuSliderRow: View {
    let icon: String
    let label: String
    let text: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @Binding var editing: Bool
    /// the trailing value slot's width — a weight title needs more
    var valueWidth: CGFloat = 44
    let commit: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15))
                .foregroundStyle(.white).frame(width: 22)
            Slider(value: $value, in: range, step: step) { e in
                editing = e
                if !e { commit() }
            }
            .tint(.wadjetAccent)
            .controlSize(.small)
            .accessibilityLabel(label)
            Text(text).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5)).frame(width: valueWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .padding(.horizontal, 14)
    }
}

extension LineEnd {
    /// accessibility/menu naming, sentence case
    var title: String {
        switch self {
        case .none: "None"
        case .openArrow: "Open arrow"
        case .filledArrow: "Filled arrow"
        case .dot: "Dot"
        case .bar: "Bar"
        }
    }
}

extension LineDash {
    var title: String {
        switch self {
        case .solid: "Solid"
        case .dashed: "Dashed"
        case .dotted: "Dotted"
        }
    }
}

/// a colour-row cell: an equal share of the row with a menu row's hover fill
struct MenuCell<Content: View>: View {
    /// held highlighted without hover — the colour well while the wheel is open
    var pinned = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State var hovering = false
    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(menuHighlight(hovering || pinned))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
    }
}

/// the hue ring + saturation/lightness triangle. Unit space is ColourWheel's:
/// centre origin, y up, triangle circumradius 1 — the view converts its
/// y-down points in. Local HSL while dragging; commits once on drag end.
struct ColourWheelView: View {
    let tool: Tool
    /// which colour of the style it edits — Draw's stroke or a shape's fill
    let target: ColourTarget
    var styles: MarkupStyles { .shared }
    @State var hsl = HSL(hue: 0, saturation: 1, lightness: 0.5)
    /// which control the current drag owns — set at drag start, held to its end
    @State var dragMode: DragMode?
    enum DragMode { case ring, triangle }

    static let size: CGFloat = 200       // ring outer diameter
    static let ringWidth: CGFloat = 18
    static var ringInner: CGFloat { size / 2 - ringWidth }          // 82
    static var triRadius: CGFloat { ringInner - 6 }                  // triangle circumradius
    static var ringMid: CGFloat { size / 2 - ringWidth / 2 }         // indicator radius

    var colour: RGBAColour { RGBAColour(hsl: hsl) }
    var pureHue: Color { Color(hue: hsl.hue / 360, saturation: 1, brightness: 1) }

    var body: some View {
        ZStack {
            // the hue ring: an angular gradient stroked into a band. SwiftUI's
            // angular gradient runs clockwise on screen from +x while hue runs
            // counter-clockwise (y up), so the stops count hues backwards
            Circle()
                .stroke(AngularGradient(colors: [0, 300, 240, 180, 120, 60, 0].map {
                    Color(hue: $0 / 360, saturation: 1, brightness: 1)
                }, center: .center), lineWidth: Self.ringWidth)
                .frame(width: Self.size - Self.ringWidth, height: Self.size - Self.ringWidth)
                .accessibilityElement()
                .accessibilityLabel("Hue")
                .accessibilityValue("\(Int(hsl.hue))°")
                .accessibilityAdjustableAction { d in adjustHue(d == .increment ? 10 : -10) }
            triangle
            indicators
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                let u = unit(v.location)
                if dragMode == nil {
                    dragMode = hypot(u.x, u.y) * Self.triRadius >= Self.ringInner ? .ring : .triangle
                }
                switch dragMode {
                case .ring?: hsl.hue = ColourWheel.hue(at: u)
                case .triangle?:
                    let sl = ColourWheel.saturationLightness(at: u, hue: hsl.hue)
                    hsl.saturation = sl.saturation; hsl.lightness = sl.lightness
                case nil: break
                }
            }
            .onEnded { _ in
                dragMode = nil
                commit()
            })
        .onAppear { seed(from: styles.colour(for: tool, target: target)) }
        .onChange(of: styles.colour(for: tool, target: target)) { _, c in seed(from: c) }
    }

    /// the S/L triangle in fixed orientation (H at unit angle 0, W 120°, K
    /// 240°), rotated into place — negative because SwiftUI rotates clockwise
    var triangle: some View {
        ZStack {
            Color.black
            // exact barycentric mix: pure hue fading to the W–K midpoint, plus
            // white fading to the H–K midpoint, over black
            LinearGradient(colors: [pureHue, pureHue.opacity(0)],
                           startPoint: unitPoint(0), endPoint: midpoint(120, 240))
                .blendMode(.plusLighter)
            LinearGradient(colors: [.white, .white.opacity(0)],
                           startPoint: unitPoint(120), endPoint: midpoint(0, 240))
                .blendMode(.plusLighter)
        }
        .compositingGroup()
        .clipShape(WheelTriangle())
        .frame(width: 2 * Self.triRadius, height: 2 * Self.triRadius)
        .rotationEffect(.degrees(-hsl.hue))
        .accessibilityElement()
        .accessibilityLabel("Saturation and lightness")
        .accessibilityValue("\(Int((hsl.saturation * 100).rounded()))%, \(Int((hsl.lightness * 100).rounded()))%")
        .accessibilityAdjustableAction { d in adjustLightness(d == .increment ? 0.05 : -0.05) }
    }

    var indicators: some View {
        ZStack {
            indicator(at: CGPoint(x: cos(hsl.hue * .pi / 180) * Self.ringMid,
                                  y: -sin(hsl.hue * .pi / 180) * Self.ringMid),
                      fill: pureHue)
            let p = ColourWheel.point(saturation: hsl.saturation, lightness: hsl.lightness, hue: hsl.hue)
            indicator(at: CGPoint(x: p.x * Self.triRadius, y: -p.y * Self.triRadius),
                      fill: Color(red: colour.red, green: colour.green, blue: colour.blue))
        }
        .allowsHitTesting(false)
    }

    func indicator(at offset: CGPoint, fill: Color) -> some View {
        Circle().fill(fill)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .offset(x: offset.x, y: offset.y)
    }

    /// a vertex's UnitPoint in the triangle's own square: unit x → (x+1)/2,
    /// unit y up → (1−y)/2
    func unitPoint(_ deg: Double) -> UnitPoint {
        let a = deg * .pi / 180
        return UnitPoint(x: (cos(a) + 1) / 2, y: (1 - sin(a)) / 2)
    }
    func midpoint(_ a: Double, _ b: Double) -> UnitPoint {
        let (pa, pb) = (unitPoint(a), unitPoint(b))
        return UnitPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
    }

    /// a view point (y down) in ColourWheel's unit space scaled by the
    /// triangle's circumradius — for the ring only the angle matters
    func unit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - Self.size / 2) / Self.triRadius,
                y: -(p.y - Self.size / 2) / Self.triRadius)
    }

    /// reseeds from a colour picked elsewhere (swatch, eyedropper); a grey has
    /// no hue, so it keeps the ring where it was
    func seed(from c: RGBAColour) {
        var h = c.hsl
        if h.saturation == 0 { h.hue = hsl.hue }
        hsl = h
    }

    func commit() {
        styles.useColour(RGBAColour(hsl: hsl), for: tool, target: target)
    }
    func adjustHue(_ delta: Double) {
        hsl.hue = (hsl.hue + delta).truncatingRemainder(dividingBy: 360)
        if hsl.hue < 0 { hsl.hue += 360 }
        commit()
    }
    func adjustLightness(_ delta: Double) {
        hsl.lightness = min(1, max(0, hsl.lightness + delta))
        commit()
    }
}

/// the S/L triangle in fixed orientation: H at unit angle 0, W 120°, K 240°
struct WheelTriangle: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ deg: Double) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY - sin(a) * r.height / 2)
        }
        var p = Path()
        p.move(to: pt(0))
        p.addLine(to: pt(120))
        p.addLine(to: pt(240))
        p.closeSubpath()
        return p
    }
}
