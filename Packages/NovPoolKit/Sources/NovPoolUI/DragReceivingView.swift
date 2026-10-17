import AppKit
import Foundation
import NovPoolCore
import NovPoolSystemBridge

/// 拖拽捕获回调桥。视图只负责「什么时候发生了什么」，业务由 `CaptureViewModel` 决定。
@MainActor
public final class DragCaptureBridge {
    /// 悬停展开扇区的稳定延时。
    public var hoverDelay: Duration = .milliseconds(150)
    public var zoneCount: Int = DropZone.defaultZones.count
    /// 环心相对画布中心的偏移，与 SwiftUI 布局共用（面板在拖拽会话中不会移动，可安全缓存）。
    public var ringOffset: CGSize = .zero
    // 回调一律声明为 @MainActor：调用点（NSDraggingDestination 回调）本来就在主线程，
    // 这样闭包体内访问视图模型不会插入运行时隔离检查。
    public var onHoverBegan: (@MainActor () -> Void)?
    public var onHoverEnded: (@MainActor () -> Void)?
    public var onZoneChanged: (@MainActor (Int?) -> Void)?
    /// 参数为解析出的内容与命中的扇区索引（`nil` 表示仍在图标死区，走智能路由）。
    public var onDrop: (@MainActor (ResolvedDragContent, Int?) -> Void)?
    public var resolver = PasteboardResolver()
    /// 拖拽事件日志，便于排查「某个浏览器拖过来没反应」。
    public var logger: (@MainActor (String) -> Void)?

    public init() {}
}

/// 注册 UTI 监听并拦截拖拽的 NSView，覆盖整个固定画布。
@MainActor
public final class DragReceivingView: NSView {
    public weak var bridge: DragCaptureBridge?

    private var hoverTask: Task<Void, Never>?
    private var hoverExpanded = false
    private var currentZone: Int?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.supportedTypes)
    }

    /// 注册的拖拽类型。
    ///
    /// 关键：浏览器拖标签的载荷格式各不相同（Firefox 只给 `text/x-moz-url`、
    /// Chrome 给 `text/uri-list`）。这些类型不在注册列表里时，系统根本不会把拖拽事件
    /// 递给我们，表现为「拖到图标上完全没反应」。
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
        fatalError("init(coder:) 未实现")
    }

    public override var isOpaque: Bool { false }

    /// 按住面板拖拽：把鼠标按下显式交给窗口做移动。
    ///
    /// 不用依赖 `isMovableByWindowBackground` 的启发式判断（视图层级、响应链稍有变化就可能失效），
    /// `NSWindow.performDrag(with:)` 是 AppKit 为「窗口内任意位置拖动」提供的正式入口。
    /// 面板是 `.nonactivatingPanel`，因此拖动过程同样不会抢走当前应用焦点。
    public override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    // MARK: - NSDraggingDestination

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let types = pasteboardTypes(sender)
        bridge?.logger?("拖拽进入：types=[\(types.joined(separator: ", "))]")
        guard !types.isEmpty else { return [] }
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
        reset()
    }

    public override func draggingEnded(_ sender: any NSDraggingInfo) {
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
            bridge.logger?("拖拽落库失败：无法解析，types=[\(pasteboardTypes(sender).joined(separator: ", "))]")
            return false
        }
        bridge.logger?("拖拽落库：type=\(content.contentType.rawValue) url=\(content.pageURL?.absoluteString ?? "无")")
        bridge.onDrop?(content, currentZone)
        return true
    }

    // MARK: - 内部

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
