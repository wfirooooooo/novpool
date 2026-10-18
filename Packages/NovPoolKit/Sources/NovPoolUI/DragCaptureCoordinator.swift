import Foundation

/// Coordinate the two drag-and-drop paths: 'native NSDraggingDestination' and 'global mouse fallback'.
///
/// Some browsers do not pass drag events to the window, so a global fallback is needed; but during normal dragging, there are two paths.
/// It will be triggered on the same release—after the native version has been successfully stored, a fallback will pop up saying 'No content recognized'.
/// This object uses a short-term suppression window to eliminate this duplicate.
@MainActor
public final class DragCaptureCoordinator {
    /// The native drag has entered the canvas (`draggingEntered`) and has not yet ended.
    private var nativeSessionActive = false
    /// The native pathway has just been successfully stored in the database, and the fallback was ignored before this.
    private var suppressFallbackUntil: Date?

    public init() {}

    public func markNativeDragEntered() {
        nativeSessionActive = true
    }

    /// Drag out the canvas or session and cancel without being registered.
    public func markNativeDragCancelled() {
        nativeSessionActive = false
    }

    /// `performDragOperation` has been successfully parsed and dispatched.
    public func markNativeDropHandled() {
        nativeSessionActive = false
        suppressFallbackUntil = Date().addingTimeInterval(0.75)
    }

    /// Should the global fallback be skipped when releasing?
    public var shouldSuppressFallback: Bool {
        if nativeSessionActive { return true }
        if let until = suppressFallbackUntil, Date() < until { return true }
        return false
    }

    /// For testing: Reset all statuses.
    public func resetForTesting() {
        nativeSessionActive = false
        suppressFallbackUntil = nil
    }
}
