import AppKit
import Foundation

/// 检索面板布局常量（非隔离，供 UI 与测试共用）。
public enum SearchPanelLayout {
    public static let contentSize = CGSize(width: 760, height: 470)
}

/// 检索面板：无边框毛玻璃卡片，需要能接收键盘输入，因此 `canBecomeKey` 为 `true`。
///
/// 与拖拽悬浮窗（`.nonactivatingPanel` + 点击穿透）正好相反：这里需要抢焦点来打字，
/// 关闭后再把焦点还给原先的前台应用。
@MainActor
public final class SearchPanel: NSPanel {
    public static let defaultContentSize = SearchPanelLayout.contentSize

    public init(contentSize: CGSize = SearchPanelLayout.contentSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // 注意：.canJoinAllSpaces 与 .moveToActiveSpace 互斥，二者同时设置会让 AppKit
        // 在构造窗口时抛 NSInternalInconsistencyException 并终止进程。
        // 检索面板是「按快捷键呼出」的，正确语义是移动到当前活跃 Space。
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        isOpaque = false
        backgroundColor = .clear
        // 圆角卡片：阴影由系统依据窗口内容的不透明区域自动生成，因此是圆角阴影。
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

/// 检索面板落位：水平居中，垂直略高于屏幕中心（Spotlight / Raycast 的习惯位置），
/// 并且跟随鼠标所在的那块屏幕。
public enum SearchPanelPlacement {
    public static func origin(
        in visibleFrame: NSRect,
        contentSize: CGSize = SearchPanelLayout.contentSize,
        verticalRatio: CGFloat = 0.72
    ) -> NSPoint {
        NSPoint(
            x: visibleFrame.midX - contentSize.width / 2,
            y: visibleFrame.minY + visibleFrame.height * verticalRatio - contentSize.height / 2
        )
    }

    /// 鼠标所在屏幕的下标（多显示器场景下按鼠标位置弹出更符合直觉）；无命中则退回首个屏幕。
    public static func screenIndex(containing point: NSPoint, frames: [NSRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        return frames.firstIndex { NSMouseInRect(point, $0, false) } ?? 0
    }

    public static func screenForMouse(screens: [NSScreen], mouseLocation: NSPoint) -> NSScreen? {
        guard let index = screenIndex(containing: mouseLocation, frames: screens.map(\.frame)) else {
            return nil
        }
        return screens[index]
    }
}
