import AppKit
import Foundation
import NovPoolCore
import NovPoolSystemBridge
import Testing
@testable import NovPoolUI

/// Use a real `NSPasteboard` + a real `DragReceivingView` to verify the browser tab drag-and-drop workflow.
///
/// Requires the WindowServer / pboard daemon; automatically skip in restricted environments without a GUI.
/// Run command: `swift test --filter DragIntegrationTests` (execute outside the sandbox if necessary).
private enum PasteboardAvailability {
    static let isAvailable: Bool = {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("novpool.probe.\(UUID().uuidString)"))
        pasteboard.clearContents()
        guard pasteboard.setString("probe", forType: .string) else { return false }
        return pasteboard.string(forType: .string) == "probe"
    }()
}

/// Only implement the members required for drag-and-drop reception.
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

@Suite("Browser tab drag-and-drop (real clipboard integration)", .enabled(if: PasteboardAvailability.isAvailable))
@MainActor
struct DragIntegrationTests {
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("novpool.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// Complete the entire receiving chain: draggingEntered → prepare → performDragOperation.
    private func runDrop(
        pasteboard: NSPasteboard,
        location: NSPoint,
        zoneCount: Int = 4
    ) -> (content: ResolvedDragContent?, zone: Int?, accepted: Bool) {
        let view = DragReceivingView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))
        let bridge = DragCaptureBridge()
        bridge.hoverDelay = .zero
        // Geometry use case fixed at 4 slots; decoupled from the product's default 'single-slot on this machine'.
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
        // In a real drag sequence, sector hits are updated in draggingUpdated.
        _ = view.draggingUpdated(info)
        let prepared = view.prepareForDragOperation(info)
        let performed = view.performDragOperation(info)
        return (captured, capturedZone, entered == .copy && prepared && performed)
    }

    @Test("Firefox tab: UTF-16LE moz-url in the real clipboard is parsed and dispatched")
    func firefoxTabDrop() throws {
        let pasteboard = makePasteboard()
        let payload = "https://example.com/firefox-tab\nFirefox Label Title"
        pasteboard.setData(payload.data(using: .utf16LittleEndian)!, forType: NSPasteboard.PasteboardType("text/x-moz-url"))
        pasteboard.setString("https://example.com/firefox-tab", forType: .string)

        let result = runDrop(pasteboard: pasteboard, location: NSPoint(x: 220, y: 220))
        #expect(result.accepted)
        #expect(result.content?.contentType == .webLink)
        #expect(result.content?.pageURL?.absoluteString == "https://example.com/firefox-tab")
        #expect(result.content?.linkTitle == "Firefox Label Title")
    }

    @Test("Chrome tab: uri-list is accepted and parsed into a URL")
    func chromeTabDrop() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString(
            "# Source:Chrome\nhttps://example.com/chrome-tab",
            forType: NSPasteboard.PasteboardType("text/uri-list")
        )

        let result = runDrop(pasteboard: pasteboard, location: NSPoint(x: 220, y: 220))
        #expect(result.accepted)
        #expect(result.content?.pageURL?.absoluteString == "https://example.com/chrome-tab")
    }

    @Test("Safari tab: public.url + public.url-name displays the title")
    func safariTabDrop() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("https://example.com/safari-tab", forType: .URL)
        pasteboard.setString("Safari Label Title", forType: NSPasteboard.PasteboardType("public.url-name"))

        let result = runDrop(pasteboard: pasteboard, location: NSPoint(x: 220, y: 220))
        #expect(result.accepted)
        #expect(result.content?.linkTitle == "Safari Label Title")
    }

    @Test("When the release position falls in the direction of a sector, return the corresponding slot index")
    func zoneDetection() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("https://example.com/zone", forType: .URL)

        // Canvas center (220,220), directly to the right falls in the first sector (index 1)
        let result = runDrop(pasteboard: pasteboard, location: NSPoint(x: 320, y: 220))
        #expect(result.accepted)
        #expect(result.zone == 1)
    }

    @Test("Release within the icon dead zone to activate smart routing (zone is nil)")
    func deadZoneMeansSmartRoute() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("https://example.com/smart", forType: .URL)

        let result = runDrop(pasteboard: pasteboard, location: NSPoint(x: 228, y: 228))
        #expect(result.accepted)
        #expect(result.zone == nil)
    }
}
