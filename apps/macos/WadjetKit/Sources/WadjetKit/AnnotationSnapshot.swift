import Synchronization

/// the Annotations on screen as last drawn, readable from the Recording's sample queue
public final class AnnotationSnapshot: Sendable {
    private let mutex = Mutex<[Annotation]>([])
    public init() {}
    public var annotations: [Annotation] {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
}
