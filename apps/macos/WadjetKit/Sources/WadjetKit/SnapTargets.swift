import CoreGraphics
import Foundation

extension SnapTarget {
    /// The snappable windows from a `CGWindowListCopyWindowInfo` listing:
    /// layer 0, alpha above 0, not owned by `pid`, and at least 40 pt wide and
    /// tall — the Freeze Frame's floor against invisible helper windows. The
    /// list's top-left global coords flip into AppKit's against `primaryHeight`.
    public static func windows(_ info: [[String: Any]], excludingOwner pid: pid_t,
                               primaryHeight: CGFloat) -> [SnapTarget] {
        info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != Int(pid),
                  let d = w[kCGWindowBounds as String] as? [String: Any],
                  let f = CGRect(dictionaryRepresentation: d as CFDictionary),
                  f.width > 40, f.height > 40 else { return nil }
            return .rect(CGRect(x: f.minX, y: primaryHeight - f.minY - f.height,
                                width: f.width, height: f.height))
        }
    }

    /// every Annotation's path bounds (geometry, not stroke), except the moving one
    public static func annotations(_ annotations: [Annotation], excluding id: Annotation.ID?) -> [SnapTarget] {
        annotations.filter { $0.id != id }.map { .rect(PathGeometry.path(for: $0).boundingBoxOfPath) }
    }
}
