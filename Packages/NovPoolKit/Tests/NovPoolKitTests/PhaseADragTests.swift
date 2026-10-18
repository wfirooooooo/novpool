import Foundation
import NovPoolCore
import Testing
@testable import NovPoolSystemBridge
@testable import NovPoolUI

@Suite("Phase A: Drag dual channels and multiple files")
struct PhaseADragTests {
    // MARK: - Coordinator

    @Test("Short-term global fallback suppression after native storage")
    @MainActor
    func coordinatorSuppressesAfterNativeDrop() {
        let coordinator = DragCaptureCoordinator()
        #expect(!coordinator.shouldSuppressFallback)

        coordinator.markNativeDragEntered()
        #expect(coordinator.shouldSuppressFallback)

        coordinator.markNativeDropHandled()
        #expect(coordinator.shouldSuppressFallback)

        coordinator.resetForTesting()
        #expect(!coordinator.shouldSuppressFallback)
    }

    @Test("Allow fallback after native drag out of the canvas")
    @MainActor
    func coordinatorAllowsFallbackAfterCancel() {
        let coordinator = DragCaptureCoordinator()
        coordinator.markNativeDragEntered()
        coordinator.markNativeDragCancelled()
        #expect(!coordinator.shouldSuppressFallback)
    }

    // MARK: - Bottom-line priority

    @Test("Fallback prioritizes using the Drag pasteboard rather than Selected text")
    func fallbackPrefersDragPasteboardOverSelection() {
        let drag = FakePasteboard(strings: [
            (PasteboardTypeID.url, "https://example.com/from-drag"),
        ])
        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: drag,
            generalPasteboard: nil,
            browser: .init(pageURL: URL(string: "https://example.com/active-tab"), pageTitle: "Label"),
            selectedText: "This selected text should not be collected"
        )
        #expect(decision?.source == "Drag pasteboard")
        #expect(decision?.content.pageURL?.absoluteString == "https://example.com/from-drag")
    }

    @Test("When there is no Drag pasteboard, fall back to the General pasteboard, and then use the Browser tab")
    func fallbackOrderGeneralThenBrowser() {
        let general = FakePasteboard(strings: [
            (PasteboardTypeID.plainText, "Clipboard Body"),
        ])
        let withGeneral = FallbackCaptureResolver.resolve(
            dragPasteboard: nil,
            generalPasteboard: general,
            browser: .init(pageURL: URL(string: "https://example.com/tab"), pageTitle: "Label"),
            selectedText: "Selected"
        )
        #expect(withGeneral?.source == "General pasteboard")
        #expect(withGeneral?.content.text == "Clipboard Body")

        let browserOnly = FallbackCaptureResolver.resolve(
            dragPasteboard: nil,
            generalPasteboard: nil,
            browser: .init(pageURL: URL(string: "https://example.com/tab"), pageTitle: "Label"),
            selectedText: "Selected"
        )
        #expect(browserOnly?.source == "Browser tab")
        #expect(browserOnly?.content.pageURL?.absoluteString == "https://example.com/tab")
    }

    @Test("Selected text is at the end")
    func fallbackSelectionIsLastResort() {
        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: nil,
            generalPasteboard: nil,
            browser: .init(pageURL: nil, pageTitle: nil),
            selectedText: "Use Selected text last"
        )
        #expect(decision?.source == "Selected text")
        #expect(decision?.content.text == "Use Selected text last")
    }

    @Test("When the Drag pasteboard retains old files, if there is a Browser tab, switch to using the tab")
    func fallbackSkipsStaleFileWhenBrowserTabAvailable() {
        let drag = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, URL(fileURLWithPath: "/tmp/old-doc.pdf").absoluteString),
        ])
        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: drag,
            generalPasteboard: nil,
            browser: .init(pageURL: URL(string: "https://example.com/tab"), pageTitle: "Current Tag"),
            selectedText: nil,
            fileExists: { _ in true }
        )
        #expect(decision?.source == "Browser tab")
        #expect(decision?.content.contentType == .webLink)
        #expect(decision?.content.pageURL?.absoluteString == "https://example.com/tab")
    }

    @Test("When the drag pasteboard has both an old File and a new Link, give priority to the Link")
    func fallbackPrefersLinkOverStaleFileOnSamePasteboard() {
        let drag = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, URL(fileURLWithPath: "/tmp/old-doc.pdf").absoluteString),
            (PasteboardTypeID.url, "https://example.com/from-drag"),
        ])
        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: drag,
            generalPasteboard: nil,
            browser: .init(pageURL: URL(string: "https://example.com/active-tab"), pageTitle: "Label"),
            selectedText: nil,
            fileExists: { _ in true }
        )
        #expect(decision?.source == "Drag pasteboard")
        #expect(decision?.content.pageURL?.absoluteString == "https://example.com/from-drag")
    }

    @Test("Accept drag pasteboard files even when there is no browser tab")
    func fallbackKeepsFileWhenNoBrowserTab() {
        let drag = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, URL(fileURLWithPath: "/tmp/report.pdf").absoluteString),
        ])
        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: drag,
            generalPasteboard: nil,
            browser: .init(pageURL: nil, pageTitle: nil),
            selectedText: nil,
            fileExists: { _ in true }
        )
        #expect(decision?.source == "Drag pasteboard")
        #expect(decision?.content.contentType == .documentPDF)
    }

    // MARK: - Expand multiple files

    @Test("Split multiple files into independent entries of each type")
    func expandMultipleFiles() {
        let png = URL(fileURLWithPath: "/tmp/a.png")
        let pdf = URL(fileURLWithPath: "/tmp/b.pdf")
        let mov = URL(fileURLWithPath: "/tmp/c.mov")
        let content = ResolvedDragContent(
            contentType: .image,
            fileURLs: [png, pdf, mov],
            matchedTypeIdentifiers: [PasteboardTypeID.fileURL]
        )
        let items = content.expandedForIngest()
        #expect(items.count == 3)
        #expect(items.map(\.contentType) == [.image, .documentPDF, .video])
        #expect(items.map { $0.fileURLs.map(\.lastPathComponent) } == [["a.png"], ["b.pdf"], ["c.mov"]])
    }

    @Test("Do not split single File and non-File content")
    func expandKeepsSinglePayload() {
        let single = ResolvedDragContent(
            contentType: .genericFile,
            fileURLs: [URL(fileURLWithPath: "/tmp/one.txt")]
        )
        #expect(single.expandedForIngest().count == 1)

        let link = ResolvedDragContent(
            contentType: .webLink,
            pageURL: URL(string: "https://example.com")
        )
        #expect(link.expandedForIngest().count == 1)
    }

    @Test("Summary of Multiple File Delivery Status Copy")
    @MainActor
    func multiFileStatusCopy() {
        let outcomes = [
            CaptureOutcome(title: "a", isDuplicate: false, routeTargets: []),
            CaptureOutcome(title: "b", isDuplicate: false, routeTargets: []),
            CaptureOutcome(title: "c", isDuplicate: true, routeTargets: []),
        ]
        #expect(CaptureViewModel.describe(outcomes) == "Saved 2, skipped 1 duplicates")
        #expect(
            CaptureViewModel.describe([
                CaptureOutcome(title: "x", isDuplicate: false, routeTargets: ["notion"]),
            ]) == "Saved → notion: x"
        )
    }
}
