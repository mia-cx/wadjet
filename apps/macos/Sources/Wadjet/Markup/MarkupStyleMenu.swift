import AppKit
import SwiftUI
import WadjetKit

extension OverlayController {
    /// headroom above the menu so its scale-in never clips; the monitor treats
    /// that strip as outside the menu body
    static let menuHeadroom: CGFloat = 40

    /// resizes the open menu's panel to its content, keeping its top edge —
    /// for a menu whose content grows (the colour wheel)
    func fitMenu() {
        guard let t = AppState.shared.openMenu, let p = menuPanel else { return }
        let size = NSHostingView(rootView: ToolMenuView(tool: t, ctrl: self)
            .padding(.top, Self.menuHeadroom)
            .frame(maxHeight: .infinity, alignment: .top)).fittingSize
        var f = p.frame
        f.origin.y = f.maxY - size.height // keep the top edge: the menu grows downward
        f.size.height = size.height
        p.setFrame(f, display: true)
    }
}

/// The Markup Tool menu: a colour row (well, recent swatches, eyedropper),
/// the expandable hue wheel, and stroke weight / opacity sliders — ToolMenuView
/// metrics, no sections.
struct MarkupStyleControls: View {
    let tool: Tool
    let ctrl: OverlayController
    @ObservedObject var s = AppState.shared
    var styles: MarkupStyles { .shared }
    @State var width: Double = 0
    @State var opacity: Double = 0

    var style: AnnotationStyle { styles.style(for: tool) }
    var colour: Color { Color(red: style.colour.red, green: style.colour.green, blue: style.colour.blue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            colourRow
            if styles.wheelOpen {
                ColourWheelView(tool: tool)
                    .frame(width: 200, height: 200)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .transition(.opacity.combined(with: .scale(0.95, anchor: .top)))
            }
            divider()
            sliderRow(icon: "lineweight", value: $width, range: 1...24, step: 1,
                      label: "Stroke weight", text: "\(Int(width)) pt") {
                styles.restyle(tool) { $0.width = CGFloat(width) }
            }
            sliderRow(icon: "circle.lefthalf.filled", value: $opacity, range: 0.1...1, step: 0.05,
                      label: "Opacity", text: "\(Int((opacity * 100).rounded()))%") {
                styles.restyle(tool) { $0.opacity = opacity }
            }
        }
        .onAppear {
            styles.refreshSwatches()
            width = Double(style.width)
            opacity = style.opacity
        }
    }

    // MARK: colour row — 8 cells: well, six swatches, eyedropper

    var colourRow: some View {
        HStack(spacing: 0) {
            MenuCell(pinned: styles.wheelOpen, action: toggleWheel) {
                // the colour well: current colour inside a rainbow ring
                Circle()
                    .stroke(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                                            center: .center), lineWidth: 2.5)
                    .frame(width: 30.5, height: 30.5)
                    .overlay { Circle().fill(colour).frame(width: 24, height: 24) }
            }
            .accessibilityLabel("Colour wheel")
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(styles.wheelOpen ? "On" : "Off")

            ForEach(0..<MarkupStyles.swatchCount, id: \.self) { i in
                if i < styles.swatches.count {
                    let c = styles.swatches[i]
                    MenuCell {
                        styles.useColour(c, for: tool)
                        s.openMenu = nil; ctrl.syncMenu()
                    } content: {
                        Circle().fill(Color(red: c.red, green: c.green, blue: c.blue))
                            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5)) // black must read on dark glass
                            .overlay { // the current colour wears a ring
                                if c.hex == style.colour.hex {
                                    Circle().stroke(.white, lineWidth: 2).padding(-2)
                                }
                            }
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel("Colour \(c.hex)")
                    .accessibilityAddTraits(c.hex == style.colour.hex ? .isSelected : [])
                } else {
                    Color.clear.frame(maxWidth: .infinity, minHeight: 40)
                }
            }

            MenuCell { styles.beginEyedropper(for: tool) } content: {
                Image(systemName: "eyedropper").font(.system(size: 15)).foregroundStyle(.white)
            }
            .accessibilityLabel("Pick colour from screen")
        }
        .frame(minHeight: 40)
    }

    func toggleWheel() {
        if styles.wheelOpen {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                styles.wheelOpen = false
            } completion: {
                ctrl.fitMenu() // the panel shrinks once the wheel has animated out
            }
        } else {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                styles.wheelOpen = true
            }
            ctrl.fitMenu() // grow at once: the content springs in inside
        }
    }

    // MARK: sliders

    /// MenuRow metrics — leading 22 pt icon, trailing value — but the row
    /// slides instead of picking, and only commits on release
    func sliderRow(icon: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                   label: String, text: String, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15))
                .foregroundStyle(.white).frame(width: 22)
            Slider(value: value, in: range, step: step) { editing in
                if !editing { commit() }
            }
            .tint(.wadjetAccent)
            .controlSize(.small)
            .accessibilityLabel(label)
            Text(text).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5)).frame(width: 44, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .padding(.horizontal, 14)
    }

    func divider() -> some View {
        Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
            .padding(.horizontal, 20).padding(.vertical, 3)
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
        .onAppear { seed(from: styles.style(for: tool).colour) }
        .onChange(of: styles.style(for: tool).colour) { _, c in seed(from: c) }
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
        styles.useColour(RGBAColour(hsl: hsl), for: tool)
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
