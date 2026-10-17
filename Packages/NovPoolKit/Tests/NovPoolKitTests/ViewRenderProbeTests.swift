import AppKit
import Foundation
import NovPoolCore
import NovPoolStorage
import SwiftUI
import Testing
@testable import NovPoolUI

/// 视图求值回归：SwiftUI 会在真实窗口渲染时求值这些闭包，
/// 一旦闭包里出现需要在运行时做隔离检查的访问，就在 release 下崩过。
/// 这里把「静默 / 展开 / 高亮」三种状态都求值一遍，至少守住"视图能被求值"这条底线。
@Suite("视图求值探针")
@MainActor
struct ViewRenderProbeTests {
    @Test("静默态与展开态都能求值")
    func panelBodyEvaluates() {
        let viewModel = CaptureViewModel { _, _ in
            CaptureOutcome(title: "探针", isDuplicate: false, routeTargets: [])
        }
        viewModel.updateRingLayout(
            SectorLayout.resolve(
                iconCenter: CGPoint(x: 220, y: 220),
                canvasSize: NovPoolLayout.canvasSize,
                visibleFrameInCanvas: CGRect(origin: .zero, size: NovPoolLayout.canvasSize)
            )
        )

        let host = NSHostingView(
            rootView: PanelRootView(viewModel: viewModel)
        )
        host.frame = NSRect(origin: .zero, size: NovPoolLayout.canvasSize)
        host.layoutSubtreeIfNeeded()
        print("=== 静默态求值完成 size=\(host.fittingSize)")

        viewModel.dragSessionBegan()
        host.layoutSubtreeIfNeeded()
        print("=== 展开态求值完成 size=\(host.fittingSize)")

        viewModel.zoneChanged(2)
        host.layoutSubtreeIfNeeded()
        print("=== 高亮态求值完成")
    }

    @Test("检索面板在空结果 / 有结果 / 失败三种状态下都能求值")
    func searchPanelBodyEvaluates() async {
        let search = SpySearch()
        search.results = [
            KnowledgeSearchResult(
                id: UUID(),
                title: "多云知识路由",
                summary: "摘要",
                category: "技术",
                tags: ["swift"],
                contentType: .webLink,
                sourceURL: URL(string: "https://example.com/a"),
                previewBody: "正文",
                isFullTextMatch: true
            ),
            KnowledgeSearchResult(
                id: UUID(),
                title: "截图预览",
                contentType: .image,
                previewBody: "## 文件信息",
                localFileURL: URL(filePath: "/tmp/novpool-probe.png")
            ),
        ]
        let viewModel = SearchViewModel(
            search: search.make(),
            actions: SpyActions().make(),
            onDismiss: {},
            debounce: .zero
        )

        let host = NSHostingView(rootView: SearchPanelView(viewModel: viewModel))
        host.frame = NSRect(origin: .zero, size: SearchPanelLayout.contentSize)
        host.layoutSubtreeIfNeeded()
        print("=== 检索面板空态求值完成")

        viewModel.activate()
        try? await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        print("=== 检索面板结果态求值完成（\(viewModel.results.count) 条）")

        search.failure = NovPoolError.database("库被锁")
        viewModel.updateQuery("触发失败")
        try? await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        print("=== 检索面板失败态求值完成")
    }
}
