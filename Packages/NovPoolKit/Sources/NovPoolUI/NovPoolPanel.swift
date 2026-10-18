import AppKit
import Foundation

/// Floating window fixed layout constants (non-isolated, shared by the UI layer and testing).
///
/// The canvas size is always 260x260 pt: **never** change the window size when hovering over an expanded sector.
/// Eliminate coordinate conversion jitter and transparent window flicker from the root.
public enum NovPoolLayout {
    /// Fixed canvas size.
    ///
    /// Much larger than the icon is **intentional**: the sector ring needs to shift inward toward the screen when it is aligned with the edge of the icon.
    /// The canvas must leave this translation space (the half span of the ring is about 117pt, so the half canvas should be at least 117 + the translation amount).
    /// The canvas itself is completely transparent and silent, allowing clicks to pass through, without occupying visual space on the desktop.
    public static let canvasSize = CGSize(width: 440, height: 440)
    public static let iconSize: CGFloat = 48
}

/// Non-focus floating panel.
///
/// Key Constraints (White Paper §3.1):
/// - The canvas size is fixed at 260x260 pt, **never** dynamically `setFrame` on hover, in order to eliminate coordinate jitter and flicker.
/// - `.nonActivatingPanel` ensures that dragging and clicking will not steal focus from the currently active window.
@MainActor
public final class NovPoolPanel: NSPanel {
    public init(canvasSize: CGSize = NovPoolLayout.canvasSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: canvasSize),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Transparency is drawn by the internal SwiftUI view itself, and the window itself does not draw any pixels.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // Allows users to hold down the icon and drag the entire panel (see `DragReceivingView.mouseDown`,
        // There, `NSWindow.performDrag(with:)` is called explicitly, without relying on this heuristic switch).
        isMovableByWindowBackground = true
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Do not enter the WindowServer's window thumbnails, reducing persistent overhead.
        sharingType = .none
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// Panel placement calculation (pure function, convenient for unit testing).
public enum PanelPlacement {
    public static let margin: CGFloat = 24
    /// The minimum visible margin retained when dragging to clamp, to prevent the icon from being half off-screen.
    public static let dragInset: CGFloat = 4

    /// Anchor the main icon to the bottom-right corner of the visible screen area (the center of the canvas coincides with the icon, and the canvas can overflow the screen).
    ///
    /// The icon corner sticker reflects the intended purpose of the product (desktop floating small icon); whether the sector is sufficient is determined by `SectorLayout`——
    /// When expanded, the center of the ring will move toward the inside of the screen, so there is no need to push the icon further into the screen for the sector.
    public static func frame(
        in visibleFrame: NSRect,
        canvasSize: CGSize = NovPoolLayout.canvasSize,
        iconSize: CGFloat = NovPoolLayout.iconSize,
        margin: CGFloat = PanelPlacement.margin
    ) -> NSRect {
        let iconCenter = NSPoint(
            x: visibleFrame.maxX - margin - iconSize / 2,
            y: visibleFrame.minY + margin + iconSize / 2
        )
        return NSRect(
            x: iconCenter.x - canvasSize.width / 2,
            y: iconCenter.y - canvasSize.height / 2,
            width: canvasSize.width,
            height: canvasSize.height
        )
    }

    /// The main icon's position in the panel coordinate system (center of the canvas).
    public static func iconRect(
        forOrigin origin: NSPoint,
        canvasSize: CGSize = NovPoolLayout.canvasSize,
        iconSize: CGFloat = NovPoolLayout.iconSize
    ) -> NSRect {
        NSRect(
            x: origin.x + (canvasSize.width - iconSize) / 2,
            y: origin.y + (canvasSize.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
    }

    /// Clamp the panel's origin to the visible screen to ensure that the icons are neither dragged away nor completely move off the screen.
    ///
    /// Rule: Choose the screen that has the largest overlapping area with the icon; if there is no overlap at all, choose the one labeled Recent.
    /// Then clip the icon into the visible area of the screen (leaving the `inset` margin).
    public static func clampedOrigin(
        _ origin: NSPoint,
        visibleFrames: [NSRect],
        canvasSize: CGSize = NovPoolLayout.canvasSize,
        iconSize: CGFloat = NovPoolLayout.iconSize,
        inset: CGFloat = PanelPlacement.dragInset
    ) -> NSPoint {
        guard let frame = targetFrame(
            forIcon: iconRect(forOrigin: origin, canvasSize: canvasSize, iconSize: iconSize),
            visibleFrames: visibleFrames
        ) else {
            return origin
        }

        let icon = iconRect(forOrigin: origin, canvasSize: canvasSize, iconSize: iconSize)
        let safe = frame.insetBy(dx: inset, dy: inset)
        // The screen is smaller than the icon (almost impossible), only ensuring that the origin is within the screen.
        let minX = min(safe.minX, safe.maxX)
        let maxX = max(safe.minX, safe.maxX)
        let minY = min(safe.minY, safe.maxY)
        let maxY = max(safe.minY, safe.maxY)

        let clampedX = min(max(icon.minX, minX), maxX - icon.width)
        let clampedY = min(max(icon.minY, minY), maxY - icon.height)
        return NSPoint(
            x: clampedX - (canvasSize.width - iconSize) / 2,
            y: clampedY - (canvasSize.height - iconSize) / 2
        )
    }

    /// Select the screen that carries the icon.
    static func targetFrame(forIcon icon: NSRect, visibleFrames: [NSRect]) -> NSRect? {
        guard !visibleFrames.isEmpty else { return nil }
        let overlaps = visibleFrames.map { frame -> (frame: NSRect, area: CGFloat) in
            let intersection = frame.intersection(icon)
            return (frame, intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        if let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 {
            return best.frame
        }
        // Completely off the screen: detach a piece from the center of the Recent icon and pull the icon back.
        let iconCenter = NSPoint(x: icon.midX, y: icon.midY)
        return visibleFrames.min { lhs, rhs in
            distance(from: iconCenter, to: lhs) < distance(from: iconCenter, to: rhs)
        }
    }

    static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
