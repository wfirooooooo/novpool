import AppKit
import Foundation
import NovPoolCore

/// 把 `NovPoolPanel`、点击穿透宿主视图与拖拽接收视图装配起来。
@MainActor
public final class PanelController: NSObject, NSWindowDelegate, DragTargetProviding {
    public let panel: NovPoolPanel
    public let viewModel: CaptureViewModel
    /// 原生拖拽与全局兜底的共享协调器。
    public let dragCoordinator: DragCaptureCoordinator

    private let hostView: PassthroughHostingView<PanelRootView>
    private let positionStore: PanelPositionStore
    private var saveTask: Task<Void, Never>?
    private let bridge: DragCaptureBridge

    public init(
        viewModel: CaptureViewModel,
        // 菜单栏常驻工具在启动瞬间未必有 key window，`NSScreen.main` 可能是 nil；
        // 回落到主显示器（screens[0] 即带菜单栏的那块）更可靠。
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
        // 拖拽诊断接到启动日志：排查「某个浏览器拖过来没反应」时，
        // 日志会直接列出该次拖拽的粘贴板类型。
        bridge.logger = { NovPoolDiagnostics.log($0) }
        self.bridge = bridge

        let dragView = DragReceivingView(frame: NSRect(origin: .zero, size: canvasSize))
        dragView.bridge = bridge

        // 宿主视图的命中区域跟随扇区展开状态切换：静默态只让中心图标接收事件。
        // 由控制器推送状态，视图不回调——避免在非隔离的 SwiftUI 生命周期闭包里访问主 actor 模型。
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

        // NSObject 子类：所有存储属性赋值必须先于 super.init()，
        // 而下面这些回调要用到 self，所以只能放在 super.init() 之后。
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

    /// 主图标在屏幕坐标系里的矩形（全局拖拽兜底通路用它判断松手位置）。
    public var iconScreenRect: CGRect {
        let icon = PassthroughHostingView<PanelRootView>.iconRect(canvasSize: panel.frame.size)
        return icon.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// 全局拖拽悬停：复用真实拖拽时的展开/收起逻辑。
    public func setGlobalDragHover(_ hovering: Bool) {
        hostView.forcesInteraction = hovering
        hostView.updateInteractiveRect(isExpanded: hovering)
        if hovering {
            viewModel.dragSessionBegan()
        } else {
            viewModel.dragSessionEnded()
        }
    }

    // MARK: - 位置：拖动 / 持久化 / 重置

    /// 恢复上次位置；没有记录或记录已不在任何屏幕上时回到默认右下角。
    private func restorePosition(fallbackScreen: NSScreen?, canvasSize: CGSize) {
        if let saved = positionStore.load() {
            let clamped = PanelPlacement.clampedOrigin(
                saved,
                // 用整块显示器范围而不是「可见区域」：允许图标停在 Dock / 菜单栏覆盖的
                // 区域，也就是「显示器任意位置停留」。误停到 Dock 后面时，
                // 菜单栏与设置面板里都有「重置悬浮窗位置」兜底。
                visibleFrames: NSScreen.screens.map(\.frame),
                canvasSize: canvasSize
            )
            panel.setFrameOrigin(clamped)
            return
        }
        guard let visibleFrame = fallbackScreen?.visibleFrame else { return }
        panel.setFrameOrigin(PanelPlacement.frame(in: visibleFrame, canvasSize: canvasSize).origin)
    }

    /// 拖到屏幕外会被立刻夹回来，落点同时持久化（去抖 0.3s，避免拖动过程中反复写盘）。
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
        // 图标换位置后，扇区环需要重新决定朝哪边让位。
        updateRingLayout()
        scheduleSave(clamped)
    }

    /// 回到默认右下角并清除记录（菜单「重置悬浮窗位置」）。
    public func resetPosition(screen: NSScreen? = NSScreen.screens.first ?? NSScreen.main) {
        positionStore.clear()
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = PanelPlacement.frame(in: visibleFrame, canvasSize: panel.frame.size).origin
        panel.setFrameOrigin(origin)
        updateRingLayout()
        scheduleSave(origin)
    }

    /// 求解扇区环的环心与半径，并同时喂给 SwiftUI 布局与拖拽命中判定。
    private func updateRingLayout() {
        let canvasSize = panel.frame.size
        let visibleFrameInCanvas = visibleFrameInCanvasCoordinates(canvasSize: canvasSize)
        let resolved = SectorLayout.resolve(
            // 主图标始终位于画布正中心。
            iconCenter: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
            canvasSize: canvasSize,
            visibleFrameInCanvas: visibleFrameInCanvas
        )
        viewModel.updateRingLayout(resolved)
        bridge.ringOffset = resolved.offset
    }


    /// 取图标所在屏幕的可见区域，换算到画布坐标（画布原点在面板左下角）。
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
