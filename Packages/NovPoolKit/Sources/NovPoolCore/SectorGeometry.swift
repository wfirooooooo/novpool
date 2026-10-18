import CoreGraphics
import Foundation

/// Sector geometry calculation: Convert the dragged hover point into the delivery slot index.
///
/// Pure mathematics, no AppKit dependency, convenient for unit testing. The coordinate system is the AppKit view coordinates (origin at the bottom left).
public enum SectorGeometry {
    /// Main icon radius (half of a 48x48 pt icon); within this radius, it is considered "not having left the icon".
    public static let deadZoneRadius: CGFloat = 24
    /// The maximum radius that a sector ring can hit (within a fixed 260x260 canvas).
    public static let maxRadius: CGFloat = 110

    /// Returns the index of the slot hit; `nil` indicates that it fell in the dead zone or outside the canvas, and should remain in a silent state.
    public static func zoneIndex(
        for point: CGPoint,
        center: CGPoint,
        zoneCount: Int
    ) -> Int? {
        guard zoneCount > 0 else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > deadZoneRadius, distance <= maxRadius else { return nil }

        // The first sector is located at the top, divided clockwise equally.
        let angleFromTop = atan2(dx, dy) // 0 = straight up; right positive, left negative
        let normalized = (angleFromTop + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let sectorWidth = 2 * CGFloat.pi / CGFloat(zoneCount)
        // First offset by half a sector and then round: this ensures the 'sector center' precisely lands on an integer index.
        // Avoid having boundary angles such as exactly up/right fall into adjacent sectors due to floating-point errors.
        let index = Int((normalized / sectorWidth + 0.5).rounded(.down))
        return index % zoneCount
    }

    /// The coordinates of the slot center relative to the canvas center, used for SwiftUI layout.
    public static func zoneCenter(index: Int, zoneCount: Int, radius: CGFloat) -> CGPoint {
        guard zoneCount > 0 else { return .zero }
        let step = 2 * CGFloat.pi / CGFloat(zoneCount)
        let angle = CGFloat(index) * step // 0 = straight up, clockwise
        return CGPoint(x: radius * sin(angle), y: radius * cos(angle))
    }
}
