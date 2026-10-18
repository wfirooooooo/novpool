import AppKit
import Foundation
import NovPoolCore

/// Assemble `NovPoolPanel` with click-through host view and drag-receiving view.
@MainActor
public final class PanelController: NSObject, NSWindowDelegate, DragTargetProviding {
    public let panel: NovPoolPanel
    public let viewModel: CaptureViewModel
    /// Native drag-and-drop with a global fallback shared coordinator.
    public let dragCoordinator: DragCaptureCoordinator

    private let hostView: PassthroughHostingView<PanelRootView>
    private let positionStore: PanelPositionStore
    private var saveTask: Task<Void, Never>?
    private let bridge: DragCaptureBridge

    public init(
        viewModel: CaptureViewModel,
        // The menu bar persistent tool may not have a key window at the moment of startup, and `NSScreen.main` could be nil;
        // Falling back to the main display (screens[0], which is the one with the menu bar) is more reliable.
        screen: NSScreen? = NSScreen.screens.first ?? NSScreen.main,
        canvasSize: CGSize = NovPoolLayout.canvasSize,
        positionStore: PanelPositionStore = PanelPositionStore(),
        dragCoordinator: DragCaptureCoordinator = DragCaptureCoordinator()
    ) {
        self.viewModel = viewModel
        self.panel = NovPoolPanel(canvasSize: canvasSize)
        self.positionStore = positionStore
        self.dragCoordinator = dragCoordinator

        let bridge = DragCaptureBridge()
        bridge.zoneCount = viewModel.zones.count
        bridge.coordinator = dragCoordinator
        // Drag-and-drop diagnostics received startup logs: when investigating 'nothing happens when dragging from a certain browser,'
        // The log will directly list the clipboard type of that drag operation.
        bridge.logger = { NovPoolDiagnostics.log($0) }
        self.bridge = bridge

        let dragView = DragReceivingView(frame: NSRect(origin: .zero, size: canvasSize))
        dragView.bridge = bridge

        // The hit area of the host view switches according to the expansion state of the sector: in silent mode, only the central icon receives events.
        // State is pushed by the controller, and the view does not callback — avoid accessing the main actor model in non-isolated SwiftUI lifecycle closures.
        let hostView = PassthroughHostingView<PanelRootView>(
            rootView: PanelRootView(
                viewModel: viewModel,
                canvasSize: canvasSize
            )
        )
        hostView.frame = NSRect(origin: .zero, size: canvasSize)
        hostView.updateInteractiveRect(isExpanded: false)
        self.hostView = hostView

        let container = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        container.addSubview(hostView)
        container.addSubview(dragView, positioned: .above, relativeTo: hostView)

        // NSObject subclass: All stored property assignments must occur before super.init().
        // And the following callbacks need to use self, so they can only be placed after super.init().
        super.init()

        panel.contentView = container

        bridge.onHoverBegan = { [weak self] in
            guard let self else { return }
            self.hostView.forcesInteraction = true
            self.hostView.updateInteractiveRect(isExpanded: true)
            self.viewModel.dragSessionBegan()
        }
        bridge.onHoverEnded = { [weak self] in
            guard let self else { return }
            self.hostView.forcesInteraction = false
            self.hostView.updateInteractiveRect(isExpanded: false)
            self.viewModel.dragSessionEnded()
        }
        bridge.onZoneChanged = { [weak self] index in
            self?.viewModel.zoneChanged(index)
        }
        bridge.onDrop = { [weak self] content, zoneIndex in
            self?.viewModel.handleDrop(content, zoneIndex: zoneIndex)
        }

        panel.delegate = self
        restorePosition(fallbackScreen: screen, canvasSize: canvasSize)
        updateRingLayout()
    }

    public func show() {
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
    }

    /// Set heat to take effect: update sector slots and synchronize drag-and-drop hit geometry.
    public func updateZones(_ zones: [DropZone]) {
        viewModel.zones = zones
        bridge.zoneCount = zones.count
        updateRingLayout()
    }

    /// The main icon's rectangle in the screen coordinate system (used to determine the release position for global drag fallback).
    public var iconScreenRect: CGRect {
        let icon = PassthroughHostingView<PanelRootView>.iconRect(canvasSize: panel.frame.size)
        return icon.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// Global drag hover: Reuse the expand/collapse logic during real dragging.
    public func setGlobalDragHover(_ hovering: Bool) {
        hostView.forcesInteraction = hovering
        hostView.updateInteractiveRect(isExpanded: hovering)
        if hovering {
            viewModel.dragSessionBegan()
        } else {
            viewModel.dragSessionEnded()
        }
    }

    // MARK: - Position: drag / persistence / reset

    /// Restore the last position; if there is no record or the record is no longer on any screen, return to the default bottom right corner.
    private func restorePosition(fallbackScreen: NSScreen?, canvasSize: CGSize) {
        if let saved = positionStore.load() {
            let clamped = PanelPlacement.clampedOrigin(
                saved,
                // Use the entire display area instead of the 'visible area': allow icons to stop on areas covered by the Dock / menu bar
                // Area, that is, 'stay anywhere on the monitor.' When it accidentally stops behind the Dock,
                // Both the menu bar and the settings panel have a 'Reset floating window position' fallback.
                visibleFrames: NSScreen.screens.map(\.frame),
                canvasSize: canvasSize
            )
            panel.setFrameOrigin(clamped)
            return
        }
        guard let visibleFrame = fallbackScreen?.visibleFrame else { return }
        panel.setFrameOrigin(PanelPlacement.frame(in: visibleFrame, canvasSize: canvasSize).origin)
    }

    /// Dragging it off the screen will immediately snap it back, and the drop point will be persisted at the same time (debounce 0.3s to avoid repeatedly writing to disk during dragging).
    public func windowDidMove(_ notification: Notification) {
        let current = panel.frame.origin
        let clamped = PanelPlacement.clampedOrigin(
            current,
            visibleFrames: NSScreen.screens.map(\.frame),
            canvasSize: panel.frame.size
        )
        if abs(clamped.x - current.x) > 0.5 || abs(clamped.y - current.y) > 0.5 {
            panel.setFrameOrigin(clamped)
        }
        // After the icon is moved, the sector ring needs to decide again which way to yield.
        updateRingLayout()
        scheduleSave(clamped)
    }

    /// Return to the default bottom right corner and clear the records (Menu "Reset floating window position").
    public func resetPosition(screen: NSScreen? = NSScreen.screens.first ?? NSScreen.main) {
        positionStore.clear()
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = PanelPlacement.frame(in: visibleFrame, canvasSize: panel.frame.size).origin
        panel.setFrameOrigin(origin)
        updateRingLayout()
        scheduleSave(origin)
    }

    /// Solve for the center and radius of a sector ring, and simultaneously feed it to SwiftUI layout and drag hit detection.
    private func updateRingLayout() {
        let canvasSize = panel.frame.size
        let visibleFrameInCanvas = visibleFrameInCanvasCoordinates(canvasSize: canvasSize)
        let resolved = SectorLayout.resolve(
            // The main icon is always positioned at the center of the canvas.
            iconCenter: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
            canvasSize: canvasSize,
            visibleFrameInCanvas: visibleFrameInCanvas
        )
        viewModel.updateRingLayout(resolved)
        bridge.ringOffset = resolved.offset
    }


    /// Get the visible area of the screen where the icon is located and convert it to canvas coordinates (the canvas origin is at the bottom left corner of the panel).
    private func visibleFrameInCanvasCoordinates(canvasSize: CGSize) -> CGRect {
        let icon = PanelPlacement.iconRect(forOrigin: panel.frame.origin, canvasSize: canvasSize)
        let screen = NSScreen.screens.first { $0.frame.intersects(icon) }
            ?? NSScreen.screens.first ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return CGRect(origin: .zero, size: canvasSize)
        }
        return visibleFrame.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
    }

    private func scheduleSave(_ origin: NSPoint) {
        saveTask?.cancel()
        let store = positionStore
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            store.save(origin)
        }
    }
}
