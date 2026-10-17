import Foundation

/// 协调「原生 NSDraggingDestination」与「全局鼠标兜底」两条拖拽通路。
///
/// 部分浏览器不会把拖拽事件递给窗口，因此需要全局兜底；但正常拖拽时两条通路
/// 会在同一次松手上都触发——原生已成功入库后，兜底再弹「没有识别到内容」。
/// 本对象用短时抑制窗口消掉这笔重复。
@MainActor
public final class DragCaptureCoordinator {
    /// 原生通路已进入画布（`draggingEntered`），尚未结束。
    private var nativeSessionActive = false
    /// 原生通路刚成功落库，在此之前忽略兜底。
    private var suppressFallbackUntil: Date?

    public init() {}

    public func markNativeDragEntered() {
        nativeSessionActive = true
    }

    /// 拖出画布或会话取消且未落库。
    public func markNativeDragCancelled() {
        nativeSessionActive = false
    }

    /// `performDragOperation` 已成功解析并投递。
    public func markNativeDropHandled() {
        nativeSessionActive = false
        suppressFallbackUntil = Date().addingTimeInterval(0.75)
    }

    /// 全局兜底在松手时应否跳过。
    public var shouldSuppressFallback: Bool {
        if nativeSessionActive { return true }
        if let until = suppressFallbackUntil, Date() < until { return true }
        return false
    }

    /// 测试用：重置全部状态。
    public func resetForTesting() {
        nativeSessionActive = false
        suppressFallbackUntil = nil
    }
}
