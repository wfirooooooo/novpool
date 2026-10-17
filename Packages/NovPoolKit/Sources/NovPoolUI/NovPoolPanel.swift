import AppKit
import Foundation

/// 悬浮窗固定布局常量（非隔离，供 UI 层与测试共用）。
///
/// 画布尺寸恒为 260x260 pt：悬停展开扇区时**绝不**改变窗口大小，
/// 从根源上消灭坐标换算抖动与透明窗口闪烁。
public enum NovPoolLayout {
    /// 固定画布尺寸。
    ///
    /// 比图标大得多是**有意为之**：扇区环需要在图标贴边时朝屏幕内侧平移，
    /// 画布必须留出这段平移空间（环半跨度约 117pt，因此半画布至少要 117 + 平移量）。
    /// 画布本身完全透明且静默态点击穿透，不占用桌面视觉空间。
    public static let canvasSize = CGSize(width: 440, height: 440)
    public static let iconSize: CGFloat = 48
}

/// 无焦点悬浮面板。
///
/// 关键约束（白皮书 §3.1）：
/// - 画布尺寸固定 260x260 pt，**永不**在悬停时动态 `setFrame`，以此消灭坐标抖动与闪烁。
/// - `.nonActivatingPanel` 保证拖拽与点击都不会抢走当前活跃窗口的焦点。
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
        // 透明由内部 SwiftUI 视图自绘，窗口本身不画任何像素。
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // 允许用户按住图标拖动整个面板（见 `DragReceivingView.mouseDown`，
        // 那里显式调用 `NSWindow.performDrag(with:)`，不依赖这条启发式开关）。
        isMovableByWindowBackground = true
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // 不进入 WindowServer 的窗口缩略图，降低常驻开销。
        sharingType = .none
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// 面板落位计算（纯函数，便于单测）。
public enum PanelPlacement {
    public static let margin: CGFloat = 24
    /// 拖动夹紧时保留的最小可见边距，避免图标半个身子贴在屏幕外。
    public static let dragInset: CGFloat = 4

    /// 把主图标锚定在屏幕可见区域的右下角（画布中心与图标重合，画布可以溢出屏幕）。
    ///
    /// 图标贴角是产品本意（桌面悬浮小图标）；扇区够不够得到由 `SectorLayout` 负责——
    /// 展开时环心会朝屏幕内侧平移，因此不必为了扇区把图标推进屏幕里面。
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

    /// 主图标在面板坐标系里的位置（画布正中央）。
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

    /// 把面板原点夹紧到可见屏幕上，保证图标既不会被拖丢、也不会整块跑出屏幕。
    ///
    /// 规则：选与图标重叠面积最大的那块屏幕；完全不重叠时选最近的一块；
    /// 然后把图标夹进该屏幕的可见区域（留 `inset` 边距）。
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
        // 屏幕比图标还小时（几乎不可能），只保证原点在屏幕内。
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

    /// 选择承载图标的屏幕。
    static func targetFrame(forIcon icon: NSRect, visibleFrames: [NSRect]) -> NSRect? {
        guard !visibleFrames.isEmpty else { return nil }
        let overlaps = visibleFrames.map { frame -> (frame: NSRect, area: CGFloat) in
            let intersection = frame.intersection(icon)
            return (frame, intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        if let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 {
            return best.frame
        }
        // 完全在屏幕外：挑离图标中心最近的一块，把图标拉回来。
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
