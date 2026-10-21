import CoreGraphics
import Foundation

/// One on-screen window as the window list reports it: CG level, AppKit global frame.
public struct ListedWindow: Equatable, Sendable {
    public var id: UInt32
    public var level: Int
    public var frame: CGRect
    public var ownedByWadjet: Bool
    public init(id: UInt32, level: Int, frame: CGRect, ownedByWadjet: Bool) {
        self.id = id
        self.level = level
        self.frame = frame
        self.ownedByWadjet = ownedByWadjet
    }
}

/// Which windows a Screenshot keeps as layers, front first, from `windows` front first.
/// Every app window at the normal level (0) over `displays` is kept; wadjet's own only at
/// level 0 and only while the shot shows wadjet (`includeWadjet`). A window at any other
/// level — a palette, the Dock, a notification — is kept only when it covers part of a kept
/// window behind it, so the flat screen's occlusion survives; menu bar extras and anything
/// else clear of kept windows stays in the flat displays.
public func windowLayerCandidates(_ windows: [ListedWindow], includeWadjet: Bool,
                                  over displays: [CGRect]) -> [ListedWindow] {
    var kept: [ListedWindow] = [] // back to front, as walked
    for w in windows.reversed() {
        guard displays.contains(where: { $0.intersects(w.frame) }) else { continue }
        if w.ownedByWadjet {
            // wadjet's own windows count only as regular app windows while the
            // shot shows wadjet; its panels and chrome never become layers
            guard includeWadjet, w.level == 0 else { continue }
        } else if w.level != 0,
                  !kept.contains(where: { $0.frame.intersects(w.frame) }) {
            continue
        }
        kept.append(w)
    }
    return kept.reversed()
}
