import AppKit
import SwiftUI

/// 像素级点击穿透宿主视图。
///
/// 静默态下，只有当鼠标落在 `interactiveRect`（默认是中心 48x48 图标区）内时才接受
/// 鼠标事件，其余区域 `hitTest` 返回 `nil`，事件原生穿透到下层桌面与浏览器窗口。
@MainActor
public final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// 响应用户事件的区域（视图坐标）。
    public var interactiveRect: NSRect = .zero
    /// 拖拽会话进行中置为 `true`，让扇区在展开后可以接收 `draggingUpdated`。
    public var forcesInteraction = false

    public required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard forcesInteraction || interactiveRect.contains(localPoint) else { return nil }
        return super.hitTest(point)
    }

    /// 由控制器按展开状态推送命中区域（视图本身不回调，避免非隔离闭包里访问主 actor 状态）。
    public func updateInteractiveRect(isExpanded: Bool) {
        interactiveRect = isExpanded
            ? NSRect(origin: .zero, size: bounds.size)
            : Self.iconRect()
    }

    /// 中心图标区。
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
