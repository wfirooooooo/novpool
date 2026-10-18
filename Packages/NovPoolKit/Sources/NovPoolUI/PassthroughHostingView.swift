import AppKit
import SwiftUI

/// Pixel-level click-through of the host view.
///
/// In silent mode, it only responds when the mouse is over the `interactiveRect` (default is the central 48x48 icon area)
/// For mouse events, the remaining areas return `nil` for `hitTest`, allowing events to naturally pass through to the underlying desktop and browser windows.
@MainActor
public final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// The area that responds to user events (view coordinates).
    public var interactiveRect: NSRect = .zero
    /// Set the drag session to `true` to allow the sector to receive `draggingUpdated` after it expands.
    public var forcesInteraction = false

    public required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard forcesInteraction || interactiveRect.contains(localPoint) else { return nil }
        return super.hitTest(point)
    }

    /// The hit area is pushed by the controller according to the expanded state (the view itself does not callback, to avoid accessing the main actor state in a non-isolated closure).
    public func updateInteractiveRect(isExpanded: Bool) {
        interactiveRect = isExpanded
            ? NSRect(origin: .zero, size: bounds.size)
            : Self.iconRect()
    }

    /// Central icon area.
    public static func iconRect(
        canvasSize: CGSize = NovPoolLayout.canvasSize,
        iconSize: CGFloat = NovPoolLayout.iconSize
    ) -> NSRect {
        NSRect(
            x: (canvasSize.width - iconSize) / 2,
            y: (canvasSize.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
    }
}
