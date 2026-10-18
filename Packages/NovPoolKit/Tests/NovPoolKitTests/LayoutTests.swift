import AppKit
import NovPoolCore
import SwiftUI
import Testing
@testable import NovPoolUI

@Suite("Floating window layout")
struct LayoutTests {
    @Test("The icon is anchored to the bottom-right corner of the visible screen area with a safe margin")
    func placementInsideVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let frame = PanelPlacement.frame(in: visible)
        #expect(frame.width == NovPoolLayout.canvasSize.width)
        #expect(frame.height == NovPoolLayout.canvasSize.height)

        // The anchor is the 'icon' rather than the canvas: the icon sticks to the corner (the product's original intention), while the canvas is allowed to overflow outside the screen.
        let icon = PanelPlacement.iconRect(forOrigin: frame.origin)
        #expect(icon.maxX == visible.maxX - PanelPlacement.margin)
        #expect(icon.minY == visible.minY + PanelPlacement.margin)
        #expect(icon.midX == frame.midX)
        #expect(icon.midY == frame.midY)
    }

    /// Given the panel origin and the visible area, calculate the screen rectangles of the four slots.
    private func chipRects(
        panelOrigin: NSPoint,
        visible: NSRect,
        canvasSize: CGSize = NovPoolLayout.canvasSize
    ) -> (rects: [NSRect], offset: CGSize, radius: CGFloat) {
        let visibleInCanvas = visible.offsetBy(dx: -panelOrigin.x, dy: -panelOrigin.y)
        let resolved = SectorLayout.resolve(
            iconCenter: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
            canvasSize: canvasSize,
            visibleFrameInCanvas: visibleInCanvas
        )
        let chipSize = SectorLayout.chipSize
        // The geometric use case is fixed to 4 slots, decoupled from the product's default number of sectors (which has been changed to a single slot on this device by default).
        let zoneCount = 4
        let rects = (0..<zoneCount).map { index -> NSRect in
            let offset = SectorGeometry.zoneCenter(
                index: index,
                zoneCount: zoneCount,
                radius: resolved.radius
            )
            // AppKit Canvas Coordinates → Screen Coordinates
            let center = NSPoint(
                x: panelOrigin.x + resolved.center.x + offset.x,
                y: panelOrigin.y + resolved.center.y + offset.y
            )
            return NSRect(
                x: center.x - chipSize.width / 2,
                y: center.y - chipSize.height / 2,
                width: chipSize.width,
                height: chipSize.height
            )
        }
        return (rects, resolved.offset, resolved.radius)
    }

    @Test("When the icon is attached to the bottom right corner of the screen, all four slots still fall within the visible area")
    func chipsReachableAtDefaultCornerParking() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let origin = PanelPlacement.frame(in: visible).origin
        let result = chipRects(panelOrigin: origin, visible: visible)

        // The center ring must face the inside of the screen; otherwise, the slots on the right/bottom will be cut off.
        #expect(result.offset != .zero)
        #expect(result.offset.width < 0)
        #expect(result.offset.height > 0)
        for (index, rect) in result.rects.enumerated() {
            #expect(visible.contains(rect), "Slot\(index) Beyond the visible area: \(rect)")
        }
    }

    @Test("When the icon is dragged to the extreme edge, the slot is still reachable")
    func chipsReachableAtExtremeEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
        // Clamp logic allows icons to be placed 8pt from the edge
        let inset = PanelPlacement.dragInset
        let iconCenter = NSPoint(
            x: visible.maxX - inset - NovPoolLayout.iconSize / 2,
            y: visible.minY + inset + NovPoolLayout.iconSize / 2
        )
        let origin = NSPoint(
            x: iconCenter.x - NovPoolLayout.canvasSize.width / 2,
            y: iconCenter.y - NovPoolLayout.canvasSize.height / 2
        )
        let result = chipRects(panelOrigin: origin, visible: visible)

        for (index, rect) in result.rects.enumerated() {
            #expect(visible.contains(rect), "Limit position slot\(index) Beyond the visible area: \(rect)")
        }
    }

    @Test("The icon does not shift when in the center of the screen, maintaining the standard four-direction circular shape")
    func noOffsetWhenCentered() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let origin = NSPoint(
            x: visible.midX - NovPoolLayout.canvasSize.width / 2,
            y: visible.midY - NovPoolLayout.canvasSize.height / 2
        )
        let result = chipRects(panelOrigin: origin, visible: visible)
        #expect(result.offset == .zero)
        #expect(result.radius == SectorLayout.preferredRadius)
        for rect in result.rects {
            #expect(visible.contains(rect))
        }
    }

    @Test("The canvas must leave enough space for the ring's translation, otherwise there will be nowhere to place the slot when aligning the corners.")
    func canvasLeavesRoomForRingShift() {
        let needed = SectorLayout.halfExtent(radius: SectorLayout.preferredRadius)
        // In corner-sticking scenarios, the center of the ring needs to be translated by (half.width - distance from the icon to the edge), and the canvas half-width must be enough to accommodate this translation.
        let iconClearance = PanelPlacement.margin + NovPoolLayout.iconSize / 2
        let requiredShift = needed.width - iconClearance
        #expect(NovPoolLayout.canvasSize.width / 2 - needed.width >= requiredShift)
        #expect(NovPoolLayout.canvasSize.height / 2 - needed.height >= requiredShift)
    }

    @Test("When the visible area is extremely small, the radius is reduced as a fallback, preventing illegal geometry.")
    func degenerateVisibleFrame() {
        let tiny = NSRect(x: 0, y: 0, width: 200, height: 160)
        let origin = NSPoint(x: -100, y: -100)
        let result = chipRects(panelOrigin: origin, visible: tiny)
        #expect(result.radius >= SectorLayout.minimumRadius)
        #expect(result.radius.isFinite)
        #expect(result.offset.width.isFinite && result.offset.height.isFinite)
    }

    @Test("Hit determination and layout share the same center: the slot center will definitely select this slot")
    func hitTestMatchesLayout() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let origin = PanelPlacement.frame(in: visible).origin
        let visibleInCanvas = visible.offsetBy(dx: -origin.x, dy: -origin.y)
        let resolved = SectorLayout.resolve(
            iconCenter: CGPoint(x: NovPoolLayout.canvasSize.width / 2, y: NovPoolLayout.canvasSize.height / 2),
            canvasSize: NovPoolLayout.canvasSize,
            visibleFrameInCanvas: visibleInCanvas
        )

        let zoneCount = 4
        for index in 0..<zoneCount {
            // SectorGeometry uses AppKit view coordinates (y-axis pointing upwards), consistent with DragReceivingView.
            let offset = SectorGeometry.zoneCenter(
                index: index,
                zoneCount: zoneCount,
                radius: resolved.radius
            )
            let probe = NSPoint(x: resolved.center.x + offset.x, y: resolved.center.y + offset.y)
            #expect(
                SectorGeometry.zoneIndex(
                    for: probe,
                    center: resolved.center,
                    zoneCount: zoneCount
                ) == index
            )
        }
    }

    @Test("The area hit in silent mode equals the center 48x48 icon area")
    @MainActor
    func iconRectIsCentered() {
        let rect = PassthroughHostingView<EmptyViewStub>.iconRect()
        #expect(rect.width == NovPoolLayout.iconSize)
        #expect(rect.height == NovPoolLayout.iconSize)
        // The hit area is always equal to the icon area at the exact center of the canvas
        #expect(rect.midX == NovPoolLayout.canvasSize.width / 2)
        #expect(rect.midY == NovPoolLayout.canvasSize.height / 2)
    }

    // MARK: - Drag and Position Persistence

    private let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)

    @Test("The icon coordinates are obtained by adding half of the canvas offset to the panel origin.")
    func iconRectFromOrigin() {
        let icon = PanelPlacement.iconRect(forOrigin: NSPoint(x: 100, y: 200))
        #expect(icon.midX == 100 + NovPoolLayout.canvasSize.width / 2)
        #expect(icon.midY == 200 + NovPoolLayout.canvasSize.height / 2)
    }

    @Test("Already legal positions are retained as is (should not be quietly moved after dragging)")
    func clampingKeepsValidOrigin() {
        let origin = NSPoint(x: 500, y: 300)
        let clamped = PanelPlacement.clampedOrigin(origin, visibleFrames: [visible])
        #expect(clamped == origin)
    }

    @Test("When dragged outside the right/top side of the screen, snap back into the visible area and maintain an 8pt margin")
    func clampingPullsBackInside() {
        let inset = PanelPlacement.dragInset
        let half = NovPoolLayout.canvasSize.width / 2

        // The center of the icon is dragged beyond the right edge of the screen
        let beyondRight = NSPoint(x: visible.maxX - half + 400, y: 300)
        let clampedRight = PanelPlacement.clampedOrigin(beyondRight, visibleFrames: [visible])
        let iconRight = PanelPlacement.iconRect(forOrigin: clampedRight)
        #expect(iconRight.maxX == visible.maxX - inset)

        // The center of the icon is dragged above the screen
        let beyondTop = NSPoint(x: 400, y: visible.maxY + 500)
        let clampedTop = PanelPlacement.clampedOrigin(beyondTop, visibleFrames: [visible])
        let iconTop = PanelPlacement.iconRect(forOrigin: clampedTop)
        #expect(iconTop.maxY == visible.maxY - inset)

        // The same applies to the lower left
        let beyondLeft = NSPoint(x: visible.minX - 900, y: visible.minY - 900)
        let clampedLeft = PanelPlacement.clampedOrigin(beyondLeft, visibleFrames: [visible])
        let iconLeft = PanelPlacement.iconRect(forOrigin: clampedLeft)
        #expect(iconLeft.minX == visible.minX + inset)
        #expect(iconLeft.minY == visible.minY + inset)
    }

    @Test("Multiple displays: Snap to the screen that overlaps the most with the icon")
    func clampingPicksOverlappingScreen() {
        let secondary = NSRect(x: 1512, y: 0, width: 1280, height: 800)
        // Most of the icons fall on the secondary screen
        let origin = NSPoint(x: 1512 + 200, y: 400)
        let clamped = PanelPlacement.clampedOrigin(origin, visibleFrames: [visible, secondary])
        #expect(clamped == origin)

        // Icon is dragged beyond the right side of the secondary screen → Clipped to the right edge of the secondary screen
        let beyond = NSPoint(x: secondary.maxX, y: 400)
        let clampedBeyond = PanelPlacement.clampedOrigin(beyond, visibleFrames: [visible, secondary])
        let icon = PanelPlacement.iconRect(forOrigin: clampedBeyond)
        #expect(icon.maxX <= secondary.maxX - PanelPlacement.dragInset + 0.001)
    }

    @Test("Snap to the Recent screen completely off-screen (e.g., when the monitor is unplugged)")
    func clampingSnapsBackFromVoid() {
        let faraway = NSPoint(x: 9_000, y: 9_000)
        let clamped = PanelPlacement.clampedOrigin(faraway, visibleFrames: [visible])
        let icon = PanelPlacement.iconRect(forOrigin: clamped)
        #expect(visible.insetBy(dx: PanelPlacement.dragInset, dy: PanelPlacement.dragInset).contains(icon))
    }

    @Test("Keep the origin when there is no screen, do not crash")
    func clampingWithoutScreens() {
        let origin = NSPoint(x: 42, y: 42)
        #expect(PanelPlacement.clampedOrigin(origin, visibleFrames: []) == origin)
    }

    @Test("The position encoding format is stable and can be read directly with defaults read.")
    func positionEncoding() {
        #expect(PanelPositionStore.encode(NSPoint(x: 12.34, y: -5.6)) == "12.3,-5.6")
        #expect(PanelPositionStore.decode("12.3,-5.6") == NSPoint(x: 12.3, y: -5.6))
        #expect(PanelPositionStore.decode("-1200.0,880.0") == NSPoint(x: -1200, y: 880))

        #expect(PanelPositionStore.decode("") == nil)
        #expect(PanelPositionStore.decode("12.3") == nil)
        #expect(PanelPositionStore.decode("abc,1") == nil)
        #expect(PanelPositionStore.decode("nan,1") == nil)
        #expect(PanelPositionStore.decode("inf,1") == nil)
    }
}

/// A placeholder type used only for instantiating a generic host view.
struct EmptyViewStub: View {
    var body: some View { EmptyView() }
}

@Suite("Menu bar icon size")
struct MenuBarIconSizingTests {
    @Test("Large bitmaps are standardized to an 18pt template image (otherwise the menu bar will appear larger by a notch)")
    @MainActor
    func normalizesPointSize() throws {
        let oversized = NSImage(size: NSSize(width: 256, height: 256))
        #expect(oversized.size.width == 256)

        let prepared = try #require(MenuBarIconSizing.prepared(oversized))
        #expect(prepared.size == MenuBarIconSizing.pointSize)
        #expect(prepared.isTemplate)
        #expect(MenuBarIconSizing.pointSize.width == 18)

        #expect(MenuBarIconSizing.prepared(nil) == nil)
    }
}
