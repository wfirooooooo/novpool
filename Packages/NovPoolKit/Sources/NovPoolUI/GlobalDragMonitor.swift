import AppKit
import Foundation

/// 全局拖拽兜底通路。
///
/// 有些浏览器（尤其拖标签）不会把拖拽事件递给我们的窗口，`NSDraggingDestination`
/// 这条链路就完全收不到东西。这里改为监听**全局鼠标事件**：
/// 按住左键移动时判断是否悬停在图标上（用于展开扇区），松手时判断是否落在图标上
/// （用于触发捕获）。鼠标事件的全局监听不需要辅助功能授权。
@MainActor
public final class GlobalDragMonitor {
    /// 图标命中区域与悬停反馈的提供者（即悬浮窗控制器）。
    public weak var target: (any DragTargetProviding)?
    /// 在图标上松手。
    public var onDrop: @MainActor () -> Void = {}
    /// 返回 `false` 时跳过本次兜底（原生通路已处理或正在处理）。
    public var shouldAcceptDrop: @MainActor () -> Bool = { true }
    public var logger: (@MainActor (String) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false
    private var movedDistance: CGFloat = 0
    private var lastPoint: CGPoint?
    private var hovering = false

    public init() {}

    /// 判定是否算「拖到图标上」：必须按下过、位移超过阈值、且落点在图标矩形内。
    ///
    /// 抽成纯函数便于验证——避免"普通点击图标也被当成拖拽",
    /// 以及避免把窗口拖动误判为内容投递。
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
        // 本地监听用于覆盖落在本应用窗口上的情况（全局监听不含本应用事件）。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
            return event
        }
        logger?("全局拖拽监控已启动")
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

    // MARK: - 事件处理

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
            logger?("鼠标松开：inside=\(inside) 位移=\(Int(movedDistance))pt")
            if inside {
                if shouldAcceptDrop() {
                    onDrop()
                } else {
                    logger?("跳过全局兜底：原生拖拽通路已处理或进行中")
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

    /// 只有真正的拖拽（位移超过阈值）才算悬停，避免普通点击也展开扇区。
    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        target?.setGlobalDragHover(value)
    }
}

/// 全局拖拽通路需要的两个能力。
@MainActor
public protocol DragTargetProviding: AnyObject {
    /// 主图标在屏幕坐标系里的矩形。
    var iconScreenRect: CGRect { get }
    /// 悬停进入/离开（用于复用展开扇区的逻辑）。
    func setGlobalDragHover(_ hovering: Bool)
}
