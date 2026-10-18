import Foundation
import NovPoolCore
import Testing
@testable import NovPoolSystemBridge
@testable import NovPoolUI

@Suite("Phase A：拖拽双通路与多文件")
struct PhaseADragTests {
    // MARK: - 协调器

    @Test("原生落库后短时抑制全局兜底")
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

    @Test("原生拖出画布后允许兜底")
    @MainActor
    func coordinatorAllowsFallbackAfterCancel() {
        let coordinator = DragCaptureCoordinator()
        coordinator.markNativeDragEntered()
        coordinator.markNativeDragCancelled()
        #expect(!coordinator.shouldSuppressFallback)
    }

    // MARK: - 兜底优先级

    @Test("兜底优先使用拖拽粘贴板，而不是选中文字")
    func fallbackPrefersDragPasteboardOverSelection() {
        let drag = FakePasteboard(strings: [
            (PasteboardTypeID.url, "https://example.com/from-drag"),
        ])
        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: drag,
            generalPasteboard: nil,
            browser: .init(pageURL: URL(string: "https://example.com/active-tab"), pageTitle: "标签"),
            selectedText: "这段选中文字不该被收"
        )
        #expect(decision?.source == "拖拽粘贴板")
        #expect(decision?.content.pageURL?.absoluteString == "https://example.com/from-drag")
    }

    @Test("无拖拽粘贴板时退到通用粘贴板，再才用浏览器标签")
    func fallbackOrderGeneralThenBrowser() {
        let general = FakePasteboard(strings: [
            (PasteboardTypeID.plainText, "粘贴板正文"),
        ])
        let withGeneral = FallbackCaptureResolver.resolve(
            dragPasteboard: nil,
            generalPasteboard: general,
            browser: .init(pageURL: URL(string: "https://example.com/tab"), pageTitle: "标签"),
            selectedText: "选中"
        )
        #expect(withGeneral?.source == "通用粘贴板")
        #expect(withGeneral?.content.text == "粘贴板正文")

        let browserOnly = FallbackCaptureResolver.resolve(
            dragPasteboard: nil,
            generalPasteboard: nil,
            browser: .init(pageURL: URL(string: "https://example.com/tab"), pageTitle: "标签"),
            selectedText: "选中"
        )
        #expect(browserOnly?.source == "浏览器标签")
        #expect(browserOnly?.content.pageURL?.absoluteString == "https://example.com/tab")
    }

    @Test("选中文字排在最后")
    func fallbackSelectionIsLastResort() {
        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: nil,
            generalPasteboard: nil,
            browser: .init(pageURL: nil, pageTitle: nil),
            selectedText: "最后才用选中文字"
        )
        #expect(decision?.source == "选中文字")
        #expect(decision?.content.text == "最后才用选中文字")
    }

    @Test("拖拽粘贴板残留旧文件时，有浏览器标签则改用标签")
    func fallbackSkipsStaleFileWhenBrowserTabAvailable() {
        let drag = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, URL(fileURLWithPath: "/tmp/old-doc.pdf").absoluteString),
        ])
        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: drag,
            generalPasteboard: nil,
            browser: .init(pageURL: URL(string: "https://example.com/tab"), pageTitle: "当前标签"),
            selectedText: nil,
            fileExists: { _ in true }
        )
        #expect(decision?.source == "浏览器标签")
        #expect(decision?.content.contentType == .webLink)
        #expect(decision?.content.pageURL?.absoluteString == "https://example.com/tab")
    }

    @Test("拖拽粘贴板同时有旧文件与新链接时，优先用链接")
    func fallbackPrefersLinkOverStaleFileOnSamePasteboard() {
        let drag = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, URL(fileURLWithPath: "/tmp/old-doc.pdf").absoluteString),
            (PasteboardTypeID.url, "https://example.com/from-drag"),
        ])
        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: drag,
            generalPasteboard: nil,
            browser: .init(pageURL: URL(string: "https://example.com/active-tab"), pageTitle: "标签"),
            selectedText: nil,
            fileExists: { _ in true }
        )
        #expect(decision?.source == "拖拽粘贴板")
        #expect(decision?.content.pageURL?.absoluteString == "https://example.com/from-drag")
    }

    @Test("无浏览器标签时仍接受拖拽粘贴板文件")
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
        #expect(decision?.source == "拖拽粘贴板")
        #expect(decision?.content.contentType == .documentPDF)
    }

    // MARK: - 多文件展开

    @Test("多文件拆成各自类型的独立条目")
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

    @Test("单文件与非文件内容不拆分")
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

    @Test("多文件投递状态文案汇总")
    @MainActor
    func multiFileStatusCopy() {
        let outcomes = [
            CaptureOutcome(title: "a", isDuplicate: false, routeTargets: []),
            CaptureOutcome(title: "b", isDuplicate: false, routeTargets: []),
            CaptureOutcome(title: "c", isDuplicate: true, routeTargets: []),
        ]
        #expect(CaptureViewModel.describe(outcomes) == "已收录 2 项，跳过 1 个重复")
        #expect(
            CaptureViewModel.describe([
                CaptureOutcome(title: "x", isDuplicate: false, routeTargets: ["notion"]),
            ]) == "已收录 → notion：x"
        )
    }
}
