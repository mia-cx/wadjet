import AppKit
import SwiftUI
import WadjetKit

extension SmartRedactCategory {
    /// the menu row's label
    var title: String {
        switch self {
        case .email: "Emails"
        case .phoneNumber: "Phone Numbers"
        case .link: "Links"
        case .cardNumber: "Card Numbers"
        case .iban: "IBANs"
        case .ipAddress: "IP Addresses"
        case .apiKey: "API Keys"
        case .face: "Faces"
        case .streetAddress: "Street Addresses"
        }
    }
    var symbol: String {
        switch self {
        case .email: "envelope"
        case .phoneNumber: "phone"
        case .link: "link"
        case .cardNumber: "creditcard"
        case .iban: "building.columns"
        case .ipAddress: "network"
        case .apiKey: "key"
        case .face: "face.smiling"
        case .streetAddress: "mappin.and.ellipse"
        }
    }
    /// the menu's row order — the enum's own order stays as declared
    static let menuOrder: [SmartRedactCategory] = [
        .email, .phoneNumber, .link, .cardNumber, .iban, .ipAddress, .apiKey, .face, .streetAddress,
    ]
}

/// the categories Smart Redact blacks out — `markup.tools.censor.smartRedact`,
/// nil = every category
@MainActor var smartRedactCategories: Set<SmartRedactCategory> {
    AppState.shared.config.value.markup.tools["censor"]?.smartRedact ?? Set(SmartRedactCategory.allCases)
}

@MainActor func setSmartRedactCategory(_ c: SmartRedactCategory, on: Bool) {
    AppState.shared.config.update {
        var set = $0.markup.tools["censor"]?.smartRedact ?? Set(SmartRedactCategory.allCases)
        if on { set.insert(c) } else { set.remove(c) }
        $0.markup.tools["censor", default: .init()].smartRedact = set
    }
}

extension Tool {
    /// the Screenshot Tools' `tools.<toolID>` settings slot; other Tools have none
    var captureSettings: WritableKeyPath<WadjetConfig.Tools, WadjetConfig.CaptureTool>? {
        switch self {
        case .capRegion: \.captureRegion
        case .capWindow: \.captureWindow
        case .capScreen: \.captureScreen
        default: nil
        }
    }
}

extension MarkupController {
    /// screen Markup reads the Freeze Frame, so it needs it up; an Editor's
    /// Canvas is already pixels — it always can
    var canSmartRedact: Bool {
        guard self === MarkupController.shared else { return true }
        guard let ctrl = AppDelegate.shared?.overlayCtrl else { return false }
        return AppState.shared.phase == .frozen && ctrl.showsFrozen
    }

    /// Blacks out every enabled category on the Freeze Frame or the Editor's
    /// flattened Canvas — one undo step. On the screen the result is dropped
    /// if the Freeze Frame it was read from went away or was replaced.
    func smartRedact() {
        guard canSmartRedact else { return }
        let onScreen = self === MarkupController.shared
        let sources: [SmartRedactSource]
        var frozen: CGImage?
        if onScreen {
            frozen = Freeze.shared.displays.first?.image
            sources = Freeze.shared.displays.map {
                SmartRedactSource(image: $0.output(hdr: false), frame: $0.screen.frame)
            }
        } else {
            guard let doc = NSDocumentController.shared.documents
                    .compactMap({ $0 as? CanvasEditorDocument }).first(where: { $0.markup === self })
            else { return }
            let canvas = doc.current // the live stack with its image assets
            let scale = canvas.layout.map(\.scaleFactor).max() ?? 2
            do {
                sources = [.init(image: try canvas.flatten(scale: scale), frame: canvas.crop)]
            } catch {
                return AppLog.line("smart redact: \(error.localizedDescription)")
            }
        }
        Task { @MainActor in
            do {
                let boxes = try await SmartRedact.boxes(in: sources, categories: smartRedactCategories)
                if onScreen, AppState.shared.phase != .frozen || Freeze.shared.displays.first?.image !== frozen {
                    return // the Freeze Frame these boxes were read on is gone
                }
                let placed = SmartRedact.censors(covering: boxes,
                                               style: MarkupStyles.shared.style(for: .censor), existing: stack)
                add(placed)
                AppLog.line("smart redact: placed \(placed.count)")
            } catch {
                AppLog.line("smart redact: \(error.localizedDescription)")
            }
        }
    }
}

extension ToolMenuView {
    /// Censor's Smart Redact controls: Redact Now, then the category toggles.
    /// The category toggles keep the menu open; Redact Now runs once and closes it.
    @ViewBuilder func smartRedactRows() -> some View {
        section("Smart Redact") {
            row("Redact Now", icon: "wand.and.rays", on: false,
                disabled: !MarkupController.active.canSmartRedact, closes: true) {
                MarkupController.active.smartRedact()
            }
            ForEach(SmartRedactCategory.menuOrder, id: \.self) { c in
                MenuRow(title: c.title, icon: c.symbol, on: smartRedactCategories.contains(c), isToggle: true) {
                    setSmartRedactCategory(c, on: !smartRedactCategories.contains(c))
                }
            }
        }
    }

    /// the Screenshot Tools' auto-redact toggle — the divider separates it
    /// from the tile row above
    @ViewBuilder func autoRedactRow() -> some View {
        if let keyPath = tool.captureSettings {
            divider()
            row("Automatic Smart Redact", icon: "eye.slash",
                on: s.config.value.tools[keyPath: keyPath].smartRedact, isToggle: true) {
                s.config.update { $0.tools[keyPath: keyPath].smartRedact.toggle() }
            }
        }
    }
}
