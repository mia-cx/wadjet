import AppKit
import SwiftUI
import WadjetKit

/// Two Rows' header frames in each toolbar panel's "panel" space, for hover mapping
enum ToolbarHeaderFrames {
    nonisolated(unsafe) static var rects: [Int: [Tool.Kind: CGRect]] = [:]
}

/// The prototype toolbar layouts (config.json `toolbarLayout`, Debug ▸ Toolbar Layout).
/// Current is the shipped row. Steady holds the row still while the pointer is inside and
/// grows it away from the pointer. Uniform gives the open group the widest group's width.
/// Two Rows puts fixed group headers on top and the shown group's Tools in a bar under them,
/// centred under the header strip. The slot maths lives in WadjetKit's ToolbarLayout.
extension ToolbarView {
    var style: ToolbarLayoutStyle { s.config.value.toolbarLayout }
    /// the Recording island keeps its one-row controls in every layout
    var twoRows: Bool { style == .twoRows && !recording }
    /// layouts whose bar moves or changes width inside a screen-wide panel, so the panel
    /// never resizes (and re-crops the glass backdrop) mid-animation
    var widePanel: Bool { style == .steady || style == .twoRows }
    var screenWidth: CGFloat { screen?.frame.width ?? 1280 }
    /// Steady's shift of the expanded bar; the collapsed island stays centred
    var barDX: CGFloat { expanded && style == .steady ? barOffset : 0 }

    /// Two Rows: the header strip's cells match the one-row toolbar's
    var headerGeo: ToolbarRowGeometry { ToolbarRowGeometry(cell: 72, gap: 8, divider: 0, edge: d + 10) }
    var headerH: CGFloat { 64 }
    var rowsGap: CGFloat { 2 }
    var stripWidth: CGFloat { headerGeo.strip(headers: Tool.Kind.allCases.count).width }
    /// where the Tool row starts, below the strip in Two Rows
    var rowTop: CGFloat { contentTop + (twoRows ? headerH + rowsGap : 0) }

    /// the Tool row's measurements, matching rowContent's HStack
    var rowGeo: ToolbarRowGeometry {
        ToolbarRowGeometry(cell: toolD, gap: cellGap, divider: 1 + 2 * ((selW - toolD) / 2 + sepMargin - cellGap),
                           edge: d + (selW - toolD) / 2)
    }
    var rowStyle: ToolbarLayoutStyle { twoRows ? .twoRows : style == .twoRows ? .current : style }
    var groupCounts: [Int] { Tool.Kind.allCases.map { groupTools($0).filter(inRow).count } }
    func groupIndex(_ k: Tool.Kind) -> Int { Tool.Kind.allCases.firstIndex(of: k) ?? 0 }
    func slotWidth(_ k: Tool.Kind) -> CGFloat {
        rowGeo.slotWidth(group: groupIndex(k), counts: groupCounts, open: groupIndex(openGroup),
                         style: rowStyle, reserve: reserve[k] ?? 0)
    }

    // MARK: Steady

    /// The held slots and bar shift that open `k` without moving `anchor` (default: the cell
    /// under the pointer). Nil outside Steady.
    func steadyHold(opening k: Tool.Kind, anchor: Tool?) -> (reserve: [Tool.Kind: CGFloat], offset: CGFloat)? {
        guard style == .steady, expanded else { return nil }
        let kinds = Tool.Kind.allCases, counts = groupCounts
        var held = reserve // the closing group keeps its width until the pointer leaves
        held[openGroup] = max(held[openGroup] ?? 0, rowGeo.openWidth(counts[groupIndex(openGroup)]))
        let before = rowGeo.row(counts: counts, open: groupIndex(openGroup), style: .steady, reserve: kinds.map { reserve[$0] ?? 0 })
        let after = rowGeo.row(counts: counts, open: groupIndex(k), style: .steady, reserve: kinds.map { held[$0] ?? 0 })
        // the bar may shift only as far as keeps it on screen and around the notch
        let lim = SteadyAnchor.limit(width: min(limit, after.width), screenWidth: screenWidth, margin: 8,
                                     keep: hasNotch ? notchW + 32 : 0)
        guard let a = anchor ?? toolUnderPointer(),
              let x0 = before.centre(group: groupIndex(a.kind), index: cellIndex(a, open: openGroup)),
              let x1 = after.centre(group: groupIndex(a.kind), index: cellIndex(a, open: k))
        else { return (held, min(max(barOffset, -lim), lim)) }
        let o = SteadyAnchor.offset(current: barOffset, before: (x0, before.width), after: (x1, after.width), limit: lim)
        AppLog.line("steady: open \(k) anchored on \(a.title), offset \(Int(barOffset)) -> \(Int(o))")
        return (held, o)
    }
    /// a Tool's index in its open group's row, nil when its group is collapsed
    func cellIndex(_ t: Tool, open: Tool.Kind) -> Int? {
        t.kind == open ? groupTools(open).filter(inRow).firstIndex(of: t) : nil
    }
    func toolUnderPointer() -> Tool? {
        guard pointerInside(), let p = ctrl.toolbarPanels[displayIndex] else { return nil }
        // window coords = the content view's, which fills the panel
        let x = p.convertPoint(fromScreen: NSEvent.mouseLocation).x
        return hitTool(at: x - (panelW / 2 + barDX - rowSize.width / 2))
    }
    /// Steady: a press on a collapsed group opens it on release, without the lens
    func opensOnRelease(_ t: Tool) -> Bool { style == .steady && t.kind != openGroup }

    /// The pointer moved onto `t`'s cell (nil: off every cell). Steady highlights a collapsed
    /// group and opens it after a 150 ms dwell; the other layouts open it at once.
    func hoverCell(_ t: Tool?) {
        guard style == .steady else { if let t { openTheGroup(t.kind) }; return }
        let k = t.flatMap { $0.kind == openGroup || toolDisabled($0) ? nil : $0.kind }
        guard k != hoverKind else { return }
        dwellTask?.cancel(); dwellTask = nil
        hoverKind = k
        guard let t, let k else { return }
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, hoverKind == k, !pressActive else { return }
            hoverKind = nil
            openTheGroup(k, anchor: t)
        }
    }
    /// Steady and Two Rows: once the pointer has left (and no menu or lens holds the bar),
    /// an expanded bar re-fits to its resting group with the normal spring
    func refitOnLeave() {
        guard style == .steady || twoRows, expanded, !hoverInside, s.openMenu == nil, !lensActive else { return }
        hoverCell(nil)
        guard openGroup != restingGroup || barOffset != 0 || !reserve.isEmpty else { return }
        AppLog.line("toolbar re-fits on leave d\(displayIndex)")
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2)) {
            openGroup = restingGroup; reserve = [:]; barOffset = 0
        }
    }
    /// the collapsed bar drops Steady's hold, unanimated (barDX is already 0)
    func resetLayoutHold() {
        dwellTask?.cancel(); dwellTask = nil
        hoverKind = nil; reserve = [:]; barOffset = 0
    }

    // MARK: Two Rows

    /// the fixed header strip: one cell per group, the shown group highlighted; the selected
    /// Tool rides as a badge on its group's header. Hovering a header swaps the bar below.
    var groupStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: headerGeo.gap) {
                ForEach(Tool.Kind.allCases, id: \.self) { k in header(k) }
            }
            .padding(.horizontal, headerGeo.edge)
            .frame(height: headerH)
            // the line between the strip and the shown group's bar
            Rectangle().fill(.white.opacity(0.14))
                .frame(width: stripWidth - 2 * headerGeo.edge, height: 1)
                .offset(y: rowsGap / 2)
                .frame(height: 0)
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named("panel")) { phase in
            ctrl.markOverlaysDirty() // loupe off while over the bar
            guard case .active(let p) = phase else { return }
            NSCursor.arrow.set()
            if let k = (ToolbarHeaderFrames.rects[displayIndex] ?? [:]).first(where: { $0.value.contains(p) })?.key {
                openTheGroup(k)
            }
        }
    }
    func header(_ k: Tool.Kind) -> some View {
        let shown = k == openGroup, sel = s.tool.flatMap { $0.kind == k ? $0 : nil }
        return VStack(spacing: 3) {
            k.iconImage.scaledToFit()
                .frame(width: 24, height: 24)
                .overlay(alignment: .bottomTrailing) {
                    if let t = sel { // the selected Tool's symbol as the badge
                        t.iconImage.scaledToFit().frame(width: 11, height: 11)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(.black.opacity(0.85)))
                            .overlay(Circle().strokeBorder(Color.wadjetAccent, lineWidth: 1))
                            .offset(x: 6, y: 4)
                    }
                }
            Text(k.groupTitle).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(.white)
        .frame(width: headerGeo.cell, height: headerH)
        .background {
            if shown { Capsule().fill(.white.opacity(0.10)).frame(width: 92, height: headerH) }
        }
        .animation(.smooth(duration: 0.15), value: shown)
        .opacity(s.recActive && k == .rec ? 0.35 : 1) // a Recording greys the video group
        .contentShape(Rectangle())
        .onTapGesture { tapHeader(k) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(k.groupTitle)
        .accessibilityValue(sel?.title ?? "")
        .accessibilityAddTraits(shown ? [.isButton, .isSelected] : .isButton)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: {
            ToolbarHeaderFrames.rects[displayIndex, default: [:]][k] = $0
        }
    }
    /// a header click shows its group and picks its last-used Tool, as a collapsed group's
    /// cell does in one row
    func tapHeader(_ k: Tool.Kind) {
        openTheGroup(k)
        let t = lastUsedTool(k)
        guard s.tool?.kind != k, !toolDisabled(t), !t.isAction else { return }
        AppDelegate.shared?.trigger(t)
    }
}

extension AppDelegate {
    /// Debug ▸ Toolbar Layout, a checkmark on the active one
    func toolbarLayoutItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Toolbar Layout", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for l in ToolbarLayoutStyle.allCases {
            let i = mi(l.title, #selector(pickToolbarLayout(_:)), on: AppState.shared.config.value.toolbarLayout == l)
            i.representedObject = l.rawValue
            sub.addItem(i)
        }
        item.submenu = sub
        return item
    }
    @objc func pickToolbarLayout(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? String, let l = ToolbarLayoutStyle(rawValue: r) else { return }
        AppState.shared.config.update { $0.toolbarLayout = l }
    }
}

extension OverlayController {
    /// a new layout rebuilds any open toolbar, so its panel takes the layout's size
    func toolbarLayoutChanged() {
        AppLog.line("toolbar layout -> \(AppState.shared.config.value.toolbarLayout.rawValue)")
        guard !toolbarPanels.isEmpty else { return }
        AppState.shared.openMenu = nil; hideMenu(); TipPanel.hide()
        AppState.shared.expandedDisplay = nil
        ToolbarBtnFrames.rects = [:]; ToolbarHeaderFrames.rects = [:]
        refreshToolbars()
    }
}
