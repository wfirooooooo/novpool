import AppKit
import Foundation
import NovPoolCore

/// Sector ring layout solution: Ensure that the four delivery slots fall as completely as possible within the visible area of the screen.
///
/// Why it is needed: Icons can be freely dragged, while sectors expand around the icon at a fixed radius. Once the icon is close to the edge of the screen,
/// The slot facing the screen will be cut off and out of reach. The approach here is **to shift the inner ring toward the inside of the screen** (the icon remains in place),
/// The translation amount is limited by the canvas size, so the four directional sectors remain fully usable even when the icon is aligned to the edge.
public enum SectorLayout {
    public static let preferredRadius: CGFloat = 84
    /// The minimum radius when space is really insufficient; below it, the slots will crowd on the icons.
    public static let minimumRadius: CGFloat = 56
    public static let chipSize = CGSize(width: 66, height: 52)

    public struct Resolved: Sendable, Equatable {
        /// Ring center (canvas coordinates).
        public var center: CGPoint
        public var radius: CGFloat

        /// Offset of the ring center relative to the canvas center; SwiftUI layout and drag hit testing share it, and the two must always be consistent.
        public var offset: CGSize {
            CGSize(width: center.x - canvasCenter.x, height: center.y - canvasCenter.y)
        }

        var canvasCenter: CGPoint
    }

    /// Solve for the center and radius of the circle.
    ///
    /// - Parameters:
    ///   - iconCenter: Main icon center (canvas coordinates)
    ///   - canvasSize: Fixed canvas size
    ///   - visibleFrameInCanvas: The rectangle of the visible screen area converted to canvas coordinates
    public static func resolve(
        iconCenter: CGPoint,
        canvasSize: CGSize,
        visibleFrameInCanvas: CGRect,
        preferredRadius: CGFloat = SectorLayout.preferredRadius,
        chipSize: CGSize = SectorLayout.chipSize
    ) -> Resolved {
        let canvasCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        var radius = preferredRadius
        var half = halfExtent(radius: radius, chipSize: chipSize)

        // When the visible area itself cannot contain the entire ring (extremely small window / extreme resolution), first reduce the radius.
        // It's better for the ring to be slightly smaller than having the slot fall outside the screen.
        let maxFitRadius = min(
            (visibleFrameInCanvas.width - chipSize.width) / 2,
            (visibleFrameInCanvas.height - chipSize.height) / 2
        )
        if maxFitRadius < radius {
            radius = max(minimumRadius, maxFitRadius)
            half = halfExtent(radius: radius, chipSize: chipSize)
        }

        let safeInScreen = visibleFrameInCanvas.insetBy(dx: half.width, dy: half.height)
        let safeInCanvas = CGRect(origin: .zero, size: canvasSize).insetBy(dx: half.width, dy: half.height)
        let safe = safeInScreen.intersection(safeInCanvas)

        guard !safe.isNull, safe.width > 0, safe.height > 0 else {
            // There isn't even a place to put a legitimate ring core: go back to unfolding the icon, at least the behavior is predictable.
            return Resolved(center: iconCenter, radius: radius, canvasCenter: canvasCenter)
        }

        let center = CGPoint(
            x: min(max(iconCenter.x, safe.minX), safe.maxX),
            y: min(max(iconCenter.y, safe.minY), safe.maxY)
        )
        return Resolved(center: center, radius: radius, canvasCenter: canvasCenter)
    }

    /// Half-span of the ring in a certain direction: radius + half-width/half-height of the slot.
    static func halfExtent(radius: CGFloat, chipSize: CGSize = SectorLayout.chipSize) -> CGSize {
        CGSize(width: radius + chipSize.width / 2, height: radius + chipSize.height / 2)
    }

    /// Pre-calculate the offset of the center of each slot (relative to the ring center), and `PanelRootView` shares the same set of geometry with hit detection.
    public static func chipOffsets(zoneCount: Int, radius: CGFloat) -> [CGPoint] {
        (0..<max(zoneCount, 0)).map { index in
            let offset = SectorGeometry.zoneCenter(index: index, zoneCount: zoneCount, radius: radius)
            // AppKit view coordinate y-axis points upward, while SectorGeometry returns the SwiftUI screen orientation offset.
            return CGPoint(x: offset.x, y: -offset.y)
        }
    }
}
