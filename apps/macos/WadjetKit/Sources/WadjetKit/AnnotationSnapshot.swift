import CoreGraphics
import Foundation
import Synchronization

/// the Annotations on screen as last drawn — and the assets their image kinds
/// draw from — readable from the Recording's sample queue
public final class AnnotationSnapshot: Sendable {
    private let mutex = Mutex<(annotations: [Annotation], images: [UUID: CGImage],
                              canvasPixels: [NestedCanvas: CanvasPixels])>(([], [:], [:]))
    public init() {}
    public var annotations: [Annotation] {
        get { mutex.withLock { $0.annotations } }
        set { mutex.withLock { $0.annotations = newValue } }
    }
    /// the pasted/dropped assets the panels last drew with — image-kind
    /// Annotations in a Record Window video need them just as the panels do
    public var images: [UUID: CGImage] {
        get { mutex.withLock { $0.images } }
        set { mutex.withLock { $0.images = newValue } }
    }
    /// cached flattens of the nested Canvases — the video's per-frame
    /// composite can't afford a fresh flatten of every one each frame
    public var canvasPixels: [NestedCanvas: CanvasPixels] {
        get { mutex.withLock { $0.canvasPixels } }
        set { mutex.withLock { $0.canvasPixels = newValue } }
    }
}
