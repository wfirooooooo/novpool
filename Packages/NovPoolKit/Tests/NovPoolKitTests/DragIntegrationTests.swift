import AppKit
import Foundation
import NovPoolCore
import NovPoolSystemBridge
import Testing
@testable import NovPoolUI

/// 用真实 `NSPasteboard` + 真实 `DragReceivingView` 验证浏览器标签拖拽链路。
///
/// 需要 WindowServer / pboard 守护进程；在无 GUI 的受限环境里自动跳过。
/// 运行方式：`swift test --filter DragIntegrationTests`（必要时在沙盒外执行）。
private enum PasteboardAvailability {
    static let isAvailable: Bool = {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("novpool.probe.\(UUID().uuidString)"))
        pasteboard.clearContents()
        guard pasteboard.setString("probe", forType: .string) else { return false }
        return pasteboard.string(forType: .string) == "probe"
    }()
}

/// 只实现拖拽接收所需的成员。
final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    var location: NSPoint

    init(pasteboard: NSPasteboard, location: NSPoint) {
        self.pasteboard = pasteboard
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}

@Suite("浏览器标签拖拽（真实粘贴板集成）", .enabled(if: PasteboardAvailability.isAvailable))
@MainActor
struct DragIntegrationTests {
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("novpool.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// 走完整的接收链路：draggingEntered → prepare → performDragOperation。
    private func runDrop(
        pasteboard: NSPasteboard,
        location: NSPoint,
        zoneCount: Int = 4
    ) -> (content: ResolvedDragContent?, zone: Int?, accepted: Bool) {
        let view = DragReceivingView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))
        let bridge = DragCaptureBridge()
        bridge.hoverDelay = .zero
        // 几何用例固定 4 槽；与产品默认「本机单槽」解耦。
        bridge.zoneCount = zoneCount
        var captured: ResolvedDragContent?
        var capturedZone: Int?
        bridge.onDrop = { content, zone in
            captured = content
            capturedZone = zone
        }
        view.bridge = bridge

        let info = TestDraggingInfo(pasteboard: pasteboard, location: location)
        let entered = view.draggingEntered(info)
        // 真实拖拽序列里，扇区命中是在 draggingUpdated 中更新的
        _ = view.draggingUpdated(info)
        let prepared = view.prepareForDragOperation(info)
        let performed = view.performDragOperation(info)
        return (captured, capturedZone, entered == .copy && prepared && performed)
    }

    @Test("Firefox 标签：真实粘贴板里的 UTF-16LE moz-url 被解析并投递")
    func firefoxTabDrop() throws {
        let pasteboard = makePasteboard()
        let payload = "https://example.com/firefox-tab\nFirefox 标签标题"
        pasteboard.setData(payload.data(using: .utf16LittleEndian)!, forType: NSPasteboard.PasteboardType("text/x-moz-url"))
        pasteboard.setString("https://example.com/firefox-tab", forType: .string)

        let result = runDrop(pasteboard: pasteboard, location: NSPoint(x: 220, y: 220))
        #expect(result.accepted)
        #expect(result.content?.contentType == .webLink)
        #expect(result.content?.pageURL?.absoluteString == "https://example.com/firefox-tab")
        #expect(result.content?.linkTitle == "Firefox 标签标题")
    }

    @Test("Chrome 标签：uri-list 被接受并解析出 URL")
    func chromeTabDrop() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString(
            "# 来源：Chrome\nhttps://example.com/chrome-tab",
            forType: NSPasteboard.PasteboardType("text/uri-list")
        )

        let result = runDrop(pasteboard: pasteboard, location: NSPoint(x: 220, y: 220))
        #expect(result.accepted)
        #expect(result.content?.pageURL?.absoluteString == "https://example.com/chrome-tab")
    }

    @Test("Safari 标签：public.url + public.url-name 带出标题")
    func safariTabDrop() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("https://example.com/safari-tab", forType: .URL)
        pasteboard.setString("Safari 标签标题", forType: NSPasteboard.PasteboardType("public.url-name"))

        let result = runDrop(pasteboard: pasteboard, location: NSPoint(x: 220, y: 220))
        #expect(result.accepted)
        #expect(result.content?.linkTitle == "Safari 标签标题")
    }

    @Test("松手位置落在扇区方向时带回对应槽位索引")
    func zoneDetection() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("https://example.com/zone", forType: .URL)

        // 画布中心 (220,220)，正右方落在第一个扇区（index 1）
        let result = runDrop(pasteboard: pasteboard, location: NSPoint(x: 320, y: 220))
        #expect(result.accepted)
        #expect(result.zone == 1)
    }

    @Test("图标死区内松手走智能路由（zone 为 nil）")
    func deadZoneMeansSmartRoute() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("https://example.com/smart", forType: .URL)

        let result = runDrop(pasteboard: pasteboard, location: NSPoint(x: 228, y: 228))
        #expect(result.accepted)
        #expect(result.zone == nil)
    }
}
