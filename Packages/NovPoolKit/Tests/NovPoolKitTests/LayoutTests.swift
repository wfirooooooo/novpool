import AppKit
import NovPoolCore
import SwiftUI
import Testing
@testable import NovPoolUI

@Suite("悬浮窗布局")
struct LayoutTests {
    @Test("图标锚定在屏幕可见区域右下角并留出安全边距")
    func placementInsideVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let frame = PanelPlacement.frame(in: visible)
        #expect(frame.width == NovPoolLayout.canvasSize.width)
        #expect(frame.height == NovPoolLayout.canvasSize.height)

        // 锚定的是「图标」而不是画布：图标贴角（产品本意），画布允许溢出屏幕外。
        let icon = PanelPlacement.iconRect(forOrigin: frame.origin)
        #expect(icon.maxX == visible.maxX - PanelPlacement.margin)
        #expect(icon.minY == visible.minY + PanelPlacement.margin)
        #expect(icon.midX == frame.midX)
        #expect(icon.midY == frame.midY)
    }

    /// 给定面板原点与可见区域，算出四个槽位的屏幕矩形。
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
        // 几何用例固定用 4 槽，与产品默认扇区数量解耦（默认已改为本机单槽）。
        let zoneCount = 4
        let rects = (0..<zoneCount).map { index -> NSRect in
            let offset = SectorGeometry.zoneCenter(
                index: index,
                zoneCount: zoneCount,
                radius: resolved.radius
            )
            // AppKit 画布坐标 → 屏幕坐标
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

    @Test("图标贴屏幕右下角时，四个槽位仍然全部落在可见区域内")
    func chipsReachableAtDefaultCornerParking() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let origin = PanelPlacement.frame(in: visible).origin
        let result = chipRects(panelOrigin: origin, visible: visible)

        // 环心必须朝屏幕内侧让位，否则右侧/下方槽位会被裁掉。
        #expect(result.offset != .zero)
        #expect(result.offset.width < 0)
        #expect(result.offset.height > 0)
        for (index, rect) in result.rects.enumerated() {
            #expect(visible.contains(rect), "槽位 \(index) 超出可见区域：\(rect)")
        }
    }

    @Test("图标被拖到最靠边的极限位置时，槽位依然可达")
    func chipsReachableAtExtremeEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
        // 夹紧逻辑允许图标贴到距边缘 8pt 处
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
            #expect(visible.contains(rect), "极限位置槽位 \(index) 超出可见区域：\(rect)")
        }
    }

    @Test("图标在屏幕中间时不偏移，保持标准四向环形")
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

    @Test("画布必须留得下环的平移量，否则贴角时槽位无处可放")
    func canvasLeavesRoomForRingShift() {
        let needed = SectorLayout.halfExtent(radius: SectorLayout.preferredRadius)
        // 贴角场景需要把环心平移 (half.width - 图标到边缘距离)，画布半宽必须容得下这个平移量。
        let iconClearance = PanelPlacement.margin + NovPoolLayout.iconSize / 2
        let requiredShift = needed.width - iconClearance
        #expect(NovPoolLayout.canvasSize.width / 2 - needed.width >= requiredShift)
        #expect(NovPoolLayout.canvasSize.height / 2 - needed.height >= requiredShift)
    }

    @Test("极小可见区域时缩小半径兜底，不会产生非法几何")
    func degenerateVisibleFrame() {
        let tiny = NSRect(x: 0, y: 0, width: 200, height: 160)
        let origin = NSPoint(x: -100, y: -100)
        let result = chipRects(panelOrigin: origin, visible: tiny)
        #expect(result.radius >= SectorLayout.minimumRadius)
        #expect(result.radius.isFinite)
        #expect(result.offset.width.isFinite && result.offset.height.isFinite)
    }

    @Test("命中判定与布局共用同一个环心：槽位中心必定选中该槽位")
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
            // SectorGeometry 用的是 AppKit 视图坐标（y 轴向上），与 DragReceivingView 一致。
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

    @Test("静默态命中区域等于中心 48x48 图标区")
    @MainActor
    func iconRectIsCentered() {
        let rect = PassthroughHostingView<EmptyViewStub>.iconRect()
        #expect(rect.width == NovPoolLayout.iconSize)
        #expect(rect.height == NovPoolLayout.iconSize)
        // 命中区域始终等于画布正中心的图标区
        #expect(rect.midX == NovPoolLayout.canvasSize.width / 2)
        #expect(rect.midY == NovPoolLayout.canvasSize.height / 2)
    }

    // MARK: - 拖动与位置持久化

    private let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)

    @Test("图标坐标由面板原点加半个画布偏移得出")
    func iconRectFromOrigin() {
        let icon = PanelPlacement.iconRect(forOrigin: NSPoint(x: 100, y: 200))
        #expect(icon.midX == 100 + NovPoolLayout.canvasSize.width / 2)
        #expect(icon.midY == 200 + NovPoolLayout.canvasSize.height / 2)
    }

    @Test("已经合法的位置原样保留（拖动后不该被悄悄挪走）")
    func clampingKeepsValidOrigin() {
        let origin = NSPoint(x: 500, y: 300)
        let clamped = PanelPlacement.clampedOrigin(origin, visibleFrames: [visible])
        #expect(clamped == origin)
    }

    @Test("拖到屏幕右侧/上方之外时夹回可见区域，并保留 8pt 边距")
    func clampingPullsBackInside() {
        let inset = PanelPlacement.dragInset
        let half = NovPoolLayout.canvasSize.width / 2

        // 图标中心被拖到屏幕右边界之外
        let beyondRight = NSPoint(x: visible.maxX - half + 400, y: 300)
        let clampedRight = PanelPlacement.clampedOrigin(beyondRight, visibleFrames: [visible])
        let iconRight = PanelPlacement.iconRect(forOrigin: clampedRight)
        #expect(iconRight.maxX == visible.maxX - inset)

        // 图标中心被拖到屏幕上方之外
        let beyondTop = NSPoint(x: 400, y: visible.maxY + 500)
        let clampedTop = PanelPlacement.clampedOrigin(beyondTop, visibleFrames: [visible])
        let iconTop = PanelPlacement.iconRect(forOrigin: clampedTop)
        #expect(iconTop.maxY == visible.maxY - inset)

        // 左下同理
        let beyondLeft = NSPoint(x: visible.minX - 900, y: visible.minY - 900)
        let clampedLeft = PanelPlacement.clampedOrigin(beyondLeft, visibleFrames: [visible])
        let iconLeft = PanelPlacement.iconRect(forOrigin: clampedLeft)
        #expect(iconLeft.minX == visible.minX + inset)
        #expect(iconLeft.minY == visible.minY + inset)
    }

    @Test("多显示器：夹紧到与图标重叠最多的那块屏幕")
    func clampingPicksOverlappingScreen() {
        let secondary = NSRect(x: 1512, y: 0, width: 1280, height: 800)
        // 图标大部分落在副屏上
        let origin = NSPoint(x: 1512 + 200, y: 400)
        let clamped = PanelPlacement.clampedOrigin(origin, visibleFrames: [visible, secondary])
        #expect(clamped == origin)

        // 图标被拖到副屏右侧之外 → 夹到副屏右边界
        let beyond = NSPoint(x: secondary.maxX, y: 400)
        let clampedBeyond = PanelPlacement.clampedOrigin(beyond, visibleFrames: [visible, secondary])
        let icon = PanelPlacement.iconRect(forOrigin: clampedBeyond)
        #expect(icon.maxX <= secondary.maxX - PanelPlacement.dragInset + 0.001)
    }

    @Test("完全在屏幕外（例如拔掉显示器）时吸附到最近的屏幕")
    func clampingSnapsBackFromVoid() {
        let faraway = NSPoint(x: 9_000, y: 9_000)
        let clamped = PanelPlacement.clampedOrigin(faraway, visibleFrames: [visible])
        let icon = PanelPlacement.iconRect(forOrigin: clamped)
        #expect(visible.insetBy(dx: PanelPlacement.dragInset, dy: PanelPlacement.dragInset).contains(icon))
    }

    @Test("没有任何屏幕时保持原点，不崩溃")
    func clampingWithoutScreens() {
        let origin = NSPoint(x: 42, y: 42)
        #expect(PanelPlacement.clampedOrigin(origin, visibleFrames: []) == origin)
    }

    @Test("位置编码格式稳定，可直接 defaults read 阅读")
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

/// 仅用于实例化泛型宿主视图的占位类型。
struct EmptyViewStub: View {
    var body: some View { EmptyView() }
}

@Suite("菜单栏图标尺寸")
struct MenuBarIconSizingTests {
    @Test("大尺寸位图被规整为标准 18pt 模板图（否则菜单栏里会大一圈）")
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
