import AppKit
import Foundation

/// Global drag-and-drop fallback path.
///
/// Some browsers (especially when dragging tabs) will not pass drag events to our window, `NSDraggingDestination`
/// This link cannot receive anything at all. Change it here to listen to **global mouse events**:
/// Determine whether the cursor is hovering over the icon while holding down the left mouse button to move (used to expand the sector), and determine whether it lands on the icon when released.
///  (Used to trigger capture). Global listening for mouse events does not require accessibility permissions.
@MainActor
public final class GlobalDragMonitor {
    /// The provider of the icon hit area and hover feedback (i.e., the floating window controller).
    public weak var target: (any DragTargetProviding)?
    /// Release on the icon.
    public var onDrop: @MainActor () -> Void = {}
    /// Return `false` to skip this fallback (the native channel has been processed or is being processed).
    public var shouldAcceptDrop: @MainActor () -> Bool = { true }
    public var logger: (@MainActor (String) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false
    private var movedDistance: CGFloat = 0
    private var lastPoint: CGPoint?
    private var hovering = false

    public init() {}

    /// Determine whether it counts as 'dragging onto an icon': the button must have been pressed, the displacement must exceed the threshold, and the landing point must be within the icon's rectangle.
    ///
    /// Make it a pure function for easier verification — avoid 'A normal icon click was treated as a drag'
    /// And to avoid mistakenly interpreting window dragging as content delivery.
    public static func isDrop(
        iconRect: CGRect,
        point: CGPoint,
        movedDistance: CGFloat,
        dropThreshold: CGFloat = 6
    ) -> Bool {
        movedDistance >= dropThreshold && iconRect.contains(point)
    }

    public func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        // Local listening is used to override situations that occur on this application's window (global listening does not include events of this application).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
            return event
        }
        logger?("Global drag monitor started")
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isPressed = false
        movedDistance = 0
        lastPoint = nil
        hovering = false
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            isPressed = true
            movedDistance = 0
            lastPoint = point
        case .leftMouseDragged:
            guard isPressed else { return }
            if let last = lastPoint {
                movedDistance += hypot(point.x - last.x, point.y - last.y)
            }
            lastPoint = point
            updateHover(point)
        case .leftMouseUp:
            guard isPressed else { return }
            isPressed = false
            updateHover(point)
            let iconRect = target?.iconScreenRect ?? .zero
            let inside = Self.isDrop(iconRect: iconRect, point: point, movedDistance: movedDistance)
            logger?("Mouse up: inside=\(inside) distance=\(Int(movedDistance))pt")
            if inside {
                if shouldAcceptDrop() {
                    onDrop()
                } else {
                    logger?("Skip global fallback: native drag path already handled or in progress")
                }
            }
            setHovering(false)
        default:
            break
        }
    }

    private func updateHover(_ point: CGPoint) {
        let inside = isPressed && movedDistance >= 6 && (target?.iconScreenRect ?? .zero).contains(point)
        setHovering(inside)
    }

    /// Only a real drag (displacement exceeding the threshold) counts as hovering, to prevent a normal click from also expanding the sector.
    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        target?.setGlobalDragHover(value)
    }
}

/// Two abilities required for global drag-and-drop pathways.
@MainActor
public protocol DragTargetProviding: AnyObject {
    /// The main icon's rectangle in the screen coordinate system.
    var iconScreenRect: CGRect { get }
    /// Hover enter/leave (used for the logic of reusing expanded sectors).
    func setGlobalDragHover(_ hovering: Bool)
}
