import AppKit
import CoreImage
import WadjetKit

/// One shared owner for the pixels Markup samples: a magnifier on one display
/// can show a viewport on another, so the LiveSamplers — still exactly one
/// stream per display — live here, scoped to the union of every sampled rect
/// on their display instead of inside each panel's CensorLayers.
@MainActor final class ScreenSamples {
    static let shared = ScreenSamples()
    /// a new frame landed or a stream was lost: re-sync sampled layers (never
    /// re-watch from here — a dead stream retries only on the next Markup render)
    var onChange: @MainActor () -> Void = {}
    private var samplers: [CGDirectDisplayID: LiveSampler] = [:]
    private var latests: [CGDirectDisplayID: LiveSample] = [:]

    /// every Markup render: each display's sampler watches the union of the
    /// sampled rects on it; a showing Freeze Frame supplies the pixels itself
    /// and pauses sampling instead
    func watch(_ rects: [CGRect]) {
        for screen in NSScreen.screens {
            let id = Self.id(of: screen)
            if samplers[id] == nil {
                let s = LiveSampler(screen: screen) { _ in }
                s.onSample = { [weak self, weak s] sample in
                    guard let s else { return }
                    self?.latests[id] = sample
                    self?.onChange()
                    s.presented(sample)
                }
                s.onLost = { [weak self] in
                    self?.latests[id] = nil
                    self?.onChange()
                }
                samplers[id] = s
            }
            guard let sampler = samplers[id] else { continue }
            if frozen(on: screen) != nil {
                sampler.watch(nil)
                latests[id] = nil // a pre-Freeze frame is stale the moment sampling resumes
            } else {
                let union = LiveSampling.union(of: rects, on: screen.frame)
                sampler.watch(union)
                if union == nil { latests[id] = nil }
            }
        }
    }

    /// the pixels a Censor or Magnify draws from on `screen`: the Freeze
    /// Frame's cursor-free image while it shows, else the latest live sample
    func source(on screen: NSScreen) -> MagnifyRenderer.Source? {
        if let fd = frozen(on: screen) { return (CIImage(cgImage: fd.clean), screen.frame) }
        return latests[Self.id(of: screen)].map { ($0.image, $0.rect) }
    }
    /// `source(on:)` of every screen whose frame intersects `rect`
    func sources(covering rect: CGRect) -> [MagnifyRenderer.Source] {
        NSScreen.screens.filter { $0.frame.intersects(rect) }.compactMap { source(on: $0) }
    }
    /// the panels are gone: every sampler stops, frames drop, samplers release
    func stop() {
        for s in samplers.values { s.watch(nil) }
        samplers = [:]
        latests = [:]
    }

    /// the Freeze Frame covering `screen`, while it actually shows — .frozen
    /// isn't proof the picture is up: with Settings' Freeze off the panels
    /// hide it, so the desktop underneath is live and gets sampled instead
    private func frozen(on screen: NSScreen) -> FrozenDisplay? {
        guard AppState.shared.phase == .frozen,
              AppDelegate.shared?.overlayCtrl.showsFrozen == true else { return nil }
        return Freeze.shared.displays.first { Self.id(of: $0.screen) == Self.id(of: screen) }
    }
    static func id(of screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
