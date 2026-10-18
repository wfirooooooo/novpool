import AppKit
import Foundation

/// 检索面板布局常量（非隔离，供 UI 与测试共用）。
public enum SearchPanelLayout {
    public static let contentSize = CGSize(width: 780, height: 520)
    public static let minimumContentSize = CGSize(width: 640, height: 400)
    public static let minimumListColumnWidth: CGFloat = 280
    public static let minimumPreviewColumnWidth: CGFloat = 260

    public static let contentSizeDefaultsKey = "novpool.searchPanel.contentSize"

    /// 读取用户拖过的窗口尺寸；非法或过小时回退默认。
    public static func resolvedContentSize(
        defaults: UserDefaults = .standard
    ) -> CGSize {
        guard let raw = defaults.string(forKey: contentSizeDefaultsKey) else {
            return contentSize
        }
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]) else {
            return contentSize
        }
        return clamp(CGSize(width: width, height: height))
    }

    public static func persistContentSize(
        _ size: CGSize,
        defaults: UserDefaults = .standard
    ) {
        let clamped = clamp(size)
        defaults.set(
            "\(Int(clamped.width.rounded()))x\(Int(clamped.height.rounded()))",
            forKey: contentSizeDefaultsKey
        )
    }

    public static func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(minimumContentSize.width, size.width),
            height: max(minimumContentSize.height, size.height)
        )
    }
}

/// 检索面板：可缩放的毛玻璃卡片，需要能接收键盘输入，因此 `canBecomeKey` 为 `true`。
///
/// 与拖拽悬浮窗（`.nonactivatingPanel` + 点击穿透）正好相反：这里需要抢焦点来打字，
/// 关闭后再把焦点还给原先的前台应用。
@MainActor
public final class SearchPanel: NSPanel {
    public static let defaultContentSize = SearchPanelLayout.contentSize

    public init(contentSize: CGSize = SearchPanelLayout.resolvedContentSize()) {
        let size = SearchPanelLayout.clamp(contentSize)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // 注意：.canJoinAllSpaces 与 .moveToActiveSpace 互斥，二者同时设置会让 AppKit
        // 在构造窗口时抛 NSInternalInconsistencyException 并终止进程。
        // 检索面板是「按快捷键呼出」的，正确语义是移动到当前活跃 Space。
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // 与设置窗口一致：用不透明系统窗口底色，避免 ultraThinMaterial 叠桌面发暗。
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        minSize = SearchPanelLayout.minimumContentSize
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
        // 理想位置：水平居中、垂直略偏上；再夹到可见区域内，避免加大面板后顶出屏幕。
        var x = visibleFrame.midX - contentSize.width / 2
        var y = visibleFrame.minY + visibleFrame.height * verticalRatio - contentSize.height / 2
        let maxX = visibleFrame.maxX - contentSize.width
        let maxY = visibleFrame.maxY - contentSize.height
        if maxX >= visibleFrame.minX {
            x = min(max(x, visibleFrame.minX), maxX)
        }
        if maxY >= visibleFrame.minY {
            y = min(max(y, visibleFrame.minY), maxY)
        }
        return NSPoint(x: x, y: y)
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
