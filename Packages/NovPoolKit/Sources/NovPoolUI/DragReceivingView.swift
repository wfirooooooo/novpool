import AppKit
import Foundation
import NovPoolCore
import NovPoolSystemBridge

/// Drag-and-drop capture callback bridge. The view is only responsible for 'when something happened,' and the business logic is determined by `CaptureViewModel`.
@MainActor
public final class DragCaptureBridge {
    /// Stable delay for expanding the sector on hover.
    public var hoverDelay: Duration = .milliseconds(150)
    public var zoneCount: Int = DropZone.defaultZones.count
    /// The offset of the ring center relative to the canvas center is shared with SwiftUI layout (the panel will not move during the Drag session and can be safely cached).
    public var ringOffset: CGSize = .zero
    // All callbacks are declared as @MainActor: the calling point (NSDraggingDestination callback) is originally on the main thread,
    // Accessing the view model inside the closure like this will not insert runtime isolation checks.
    public var onHoverBegan: (@MainActor () -> Void)?
    public var onHoverEnded: (@MainActor () -> Void)?
    public var onZoneChanged: (@MainActor (Int?) -> Void)?
    /// The parameter is the parsed content and the index of the hit sector (`nil` indicates it is still in the icon dead zone and will use intelligent routing).
    public var onDrop: (@MainActor (ResolvedDragContent, Int?) -> Void)?
    public var resolver = PasteboardResolver()
    /// Share with the global mouse fallback to avoid double triggering from the same release.
    public var coordinator: DragCaptureCoordinator?
    /// Drag event logs, making it easier to troubleshoot 'a certain browser dragging over doesn’t respond'.
    public var logger: (@MainActor (String) -> Void)?

    public init() {}
}

/// Register a UTI listener and intercept dragged NSViews, covering the entire fixed canvas.
@MainActor
public final class DragReceivingView: NSView {
    public weak var bridge: DragCaptureBridge?

    private var hoverTask: Task<Void, Never>?
    private var hoverExpanded = false
    private var currentZone: Int?
    /// Whether the current round of `performDragOperation` has been successfully delivered (to avoid `draggingEnded` mistakenly clearing the suppression window).
    private var dropHandled = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.supportedTypes)
    }

    /// Registered drag type.
    ///
    /// Key: The load format when dragging tabs in browsers varies (Firefox only provides `text/x-moz-url`,
    /// Chrome gives `text/uri-list`). When these types are not in the registered list, the system simply does not trigger the drag event
    /// Hand it to us, it appears as 'no response at all when dragged onto the icon'.
    static var supportedTypes: [NSPasteboard.PasteboardType] {
        [
            .fileURL, .URL, .tiff, .png, .html, .string, .pdf,
            .init(PasteboardTypeID.urlName),
            .init(PasteboardTypeID.uriList),
            .init(PasteboardTypeID.mozURL),
            .init(PasteboardTypeID.mozURLData),
            .init(PasteboardTypeID.mpeg4Movie),
            .init(PasteboardTypeID.movie),
            .init(PasteboardTypeID.quickTimeMovie),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isOpaque: Bool { false }

    /// Hold the panel and drag: Press the mouse to explicitly hand over the movement to the window.
    ///
    /// Do not rely on the heuristic judgment of `isMovableByWindowBackground` (it may fail if the view hierarchy or responder chain changes slightly),
    /// `NSWindow.performDrag(with:)` is the official entry point provided by AppKit for 'dragging from any position within the window'.
    /// The panel is `.nonactivatingPanel`, so the dragging process will also not take away the current application focus.
    public override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    // MARK: - NSDraggingDestination

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let types = pasteboardTypes(sender)
        bridge?.logger?("Drag entered: types=[\(types.joined(separator: ", "))]")
        guard !types.isEmpty else { return [] }
        dropHandled = false
        bridge?.coordinator?.markNativeDragEntered()
        scheduleHoverExpansion()
        return .copy
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !pasteboardTypes(sender).isEmpty else { return [] }
        let zone = zoneIndex(for: sender.draggingLocation)
        if zone != currentZone {
            currentZone = zone
            bridge?.onZoneChanged?(zone)
        }
        return .copy
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if !dropHandled {
            bridge?.coordinator?.markNativeDragCancelled()
        }
        reset()
    }

    public override func draggingEnded(_ sender: any NSDraggingInfo) {
        // perform markNativeDropHandled and open short-term suppression when successful; in other cases, clear the session.
        if !dropHandled {
            bridge?.coordinator?.markNativeDragCancelled()
        }
        dropHandled = false
        reset()
    }

    public override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !pasteboardTypes(sender).isEmpty
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { reset() }
        guard let bridge else { return false }
        let reader = NSPasteboardReader(pasteboard: sender.draggingPasteboard)
        guard let content = bridge.resolver.resolve(from: reader) else {
            bridge.logger?("Drag capture failed: could not resolve, types=[\(pasteboardTypes(sender).joined(separator: ", "))]")
            bridge.coordinator?.markNativeDragCancelled()
            dropHandled = false
            return false
        }
        bridge.logger?("Drag captured: type=\(content.contentType.rawValue) url=\(content.pageURL?.absoluteString ?? "none")")
        dropHandled = true
        bridge.coordinator?.markNativeDropHandled()
        bridge.onDrop?(content, currentZone)
        return true
    }

    // MARK: - Internals

    private func pasteboardTypes(_ sender: any NSDraggingInfo) -> [String] {
        (sender.draggingPasteboard.types ?? []).map(\.rawValue)
    }

    private func scheduleHoverExpansion() {
        guard !hoverExpanded else { return }
        hoverTask?.cancel()
        let delay = bridge?.hoverDelay ?? .milliseconds(150)
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.hoverExpanded = true
            self.bridge?.onHoverBegan?()
        }
    }

    private func zoneIndex(for windowLocation: NSPoint) -> Int? {
        let localPoint = convert(windowLocation, from: nil)
        let count = bridge?.zoneCount ?? DropZone.defaultZones.count
        let offset = bridge?.ringOffset ?? .zero
        return SectorGeometry.zoneIndex(
            for: localPoint,
            center: CGPoint(x: bounds.midX + offset.width, y: bounds.midY + offset.height),
            zoneCount: count
        )
    }

    private func reset() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverExpanded = false
        currentZone = nil
        bridge?.onHoverEnded?()
    }
}
