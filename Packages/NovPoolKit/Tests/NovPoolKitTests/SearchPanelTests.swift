import AppKit
import Carbon.HIToolbox
import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolUI

/// 记录动作调用的替身（全局 actor 隔离，测试无需加锁）。
@MainActor
final class SpyActions {
    private(set) var openedURLs: [URL] = []
    private(set) var revealedFiles: [URL] = []
    private(set) var copiedText: [String] = []
    private(set) var deletedIDs: [UUID] = []
    private(set) var quickLookedFiles: [URL] = []
    private(set) var dismissCount = 0

    func make() -> SearchActions {
        SearchActions(
            openURL: { [self] in openedURLs.append($0) },
            revealFile: { [self] in revealedFiles.append($0) },
            copyText: { [self] in copiedText.append($0) },
            deleteItem: { [self] id in
                deletedIDs.append(id)
                return true
            },
            quickLookFile: { [self] in quickLookedFiles.append($0) }
        )
    }
}

/// 记录查询串并返回预置结果的替身。
@MainActor
final class SpySearch {
    private(set) var queries: [String] = []
    var results: [KnowledgeSearchResult] = []
    var failure: Error?

    func make() -> @MainActor @Sendable (String) async throws -> [KnowledgeSearchResult] {
        { [self] query in
            queries.append(query)
            if let failure { throw failure }
            return results
        }
    }
}

@Suite("检索面板行为")
@MainActor
struct SearchPanelTests {
    private func makeViewModel(
        search: SpySearch = SpySearch(),
        actions: SpyActions = SpyActions(),
        onDismiss: @escaping @MainActor () -> Void = {}
    ) -> (SearchViewModel, SpySearch, SpyActions) {
        let viewModel = SearchViewModel(
            search: search.make(),
            actions: actions.make(),
            onDismiss: onDismiss,
            debounce: .zero
        )
        return (viewModel, search, actions)
    }

    private func sample(
        title: String = "条目",
        url: String? = nil,
        fileURL: URL? = nil,
        summary: String? = nil
    ) -> KnowledgeSearchResult {
        KnowledgeSearchResult(
            id: UUID(),
            title: title,
            summary: summary,
            contentType: .webLink,
            sourceURL: url.flatMap(URL.init(string:)),
            previewBody: "正文",
            localFileURL: fileURL
        )
    }

    /// 等待去抖 Task 跑完。
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: - 生命周期

    @Test("唤起面板：清空查询、递增聚焦令牌、先加载最近条目")
    func activateLoadsRecent() async {
        let search = SpySearch()
        search.results = [sample(title: "最近条目")]
        let (viewModel, spy, _) = makeViewModel(search: search)

        viewModel.updateQuery("残留的旧查询")
        await settle()
        viewModel.activate()
        await settle()

        #expect(viewModel.query.isEmpty)
        #expect(viewModel.focusToken == 1)
        #expect(spy.queries.last == "")
        #expect(viewModel.results.count == 1)
        #expect(viewModel.phase == .results)
        #expect(viewModel.selectedIndex == 0)
    }

    @Test("输入触发检索，结果就绪后选中项回到第一条")
    func queryDrivesSearch() async {
        let search = SpySearch()
        search.results = [sample(title: "甲"), sample(title: "乙"), sample(title: "丙")]
        let (viewModel, spy, _) = makeViewModel(search: search)

        viewModel.activate()
        await settle()
        viewModel.moveSelection(by: 2)
        #expect(viewModel.selectedIndex == 2)

        viewModel.updateQuery("多云路由")
        await settle()

        #expect(spy.queries.last == "多云路由")
        #expect(viewModel.selectedIndex == 0)
        #expect(viewModel.phase == .results)
        #expect(viewModel.isBusy == false)
    }

    @Test("无结果与检索失败都有明确状态，面板不会卡在空白")
    func emptyAndFailureStates() async {
        let search = SpySearch()
        search.results = []
        let (viewModel, _, _) = makeViewModel(search: search)
        viewModel.activate()
        await settle()
        #expect(viewModel.phase == .empty)

        let failing = SpySearch()
        failing.failure = NovPoolError.database("库被锁住")
        let (failingViewModel, _, _) = makeViewModel(search: failing)
        failingViewModel.activate()
        await settle()
        if case .failed(let message) = failingViewModel.phase {
            #expect(message.contains("库被锁住"))
        } else {
            Issue.record("检索失败时应进入 failed 状态，实际是 \(failingViewModel.phase)")
        }
        #expect(failingViewModel.results.isEmpty)
    }

    // MARK: - 选择

    @Test("上下移动在两端夹紧，不会越界")
    func selectionClamping() async {
        let search = SpySearch()
        search.results = [sample(title: "甲"), sample(title: "乙")]
        let (viewModel, _, _) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.moveSelection(by: -1)
        #expect(viewModel.selectedIndex == 0)
        viewModel.moveSelection(by: 5)
        #expect(viewModel.selectedIndex == 1)
        viewModel.select(99)
        #expect(viewModel.selectedIndex == 1)
        #expect(viewModel.selectedResult?.title == "乙")
    }

    @Test("结果为空时移动选择不崩溃")
    func selectionWithNoResults() async {
        let search = SpySearch()
        search.results = []
        let (viewModel, _, _) = makeViewModel(search: search)
        viewModel.activate()
        await settle()
        viewModel.moveSelection(by: 1)
        #expect(viewModel.selectedResult == nil)
    }

    // MARK: - 动作

    @Test("回车打开网页条目并收起面板")
    func confirmOpensWebResult() async {
        let search = SpySearch()
        search.results = [sample(title: "文章", url: "https://example.com/a")]
        var dismissed = 0
        let (viewModel, _, actions) = makeViewModel(search: search, onDismiss: { dismissed += 1 })
        viewModel.activate()
        await settle()

        viewModel.confirmSelection()
        #expect(actions.openedURLs == [URL(string: "https://example.com/a")!])
        #expect(actions.revealedFiles.isEmpty)
        #expect(dismissed == 1)
    }

    @Test("回车打开纯本地文件条目")
    func confirmRevealsLocalFile() async {
        let file = URL(filePath: "/tmp/novpool-report.pdf")
        let search = SpySearch()
        search.results = [sample(title: "本地报告", fileURL: file)]
        var dismissed = 0
        let (viewModel, _, actions) = makeViewModel(search: search, onDismiss: { dismissed += 1 })
        viewModel.activate()
        await settle()

        viewModel.confirmSelection()
        #expect(actions.revealedFiles == [file])
        #expect(actions.openedURLs.isEmpty)
        #expect(dismissed == 1)
    }

    @Test("既无链接也无文件的条目回退为复制，避免回车毫无反应")
    func confirmFallsBackToCopy() async {
        let search = SpySearch()
        search.results = [sample(title: "纯文本笔记", summary: "摘要")]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.confirmSelection()
        #expect(actions.copiedText.count == 1)
        #expect(actions.copiedText[0].contains("纯文本笔记"))
    }

    @Test("复制按钮写入剪贴板文本")
    func copySelection() async {
        let search = SpySearch()
        search.results = [sample(title: "甲"), sample(title: "乙")]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.moveSelection(by: 1)
        viewModel.copySelection()
        #expect(actions.copiedText.count == 1)
        #expect(actions.copiedText[0].contains("# 乙"))
    }

    @Test("删除选中条目后从结果列表移除")
    func deleteSelectionRemovesResult() async {
        let search = SpySearch()
        let first = sample(title: "甲")
        let second = sample(title: "乙")
        search.results = [first, second]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.deleteSelection()
        await settle()

        #expect(actions.deletedIDs == [first.id])
        #expect(viewModel.results.map(\.title) == ["乙"])
        #expect(viewModel.selectedResult?.title == "乙")
    }

    @Test("按类型与时间筛选收窄结果")
    func filtersNarrowResults() async {
        let search = SpySearch()
        let web = KnowledgeSearchResult(
            id: UUID(),
            title: "网页",
            contentType: .webLink,
            sourceURL: URL(string: "https://example.com"),
            createdAt: Date()
        )
        let oldFile = KnowledgeSearchResult(
            id: UUID(),
            title: "旧文件",
            contentType: .genericFile,
            createdAt: Date().addingTimeInterval(-40 * 24 * 3600)
        )
        search.results = [web, oldFile]
        let (viewModel, _, _) = makeViewModel(search: search)
        viewModel.activate()
        await settle()
        #expect(viewModel.results.count == 2)

        viewModel.setContentKindFilter(.web)
        #expect(viewModel.results.map(\.title) == ["网页"])

        viewModel.setContentKindFilter(.file)
        viewModel.setTimeFilter(.month)
        #expect(viewModel.results.isEmpty)

        viewModel.clearFilters()
        #expect(viewModel.results.count == 2)
    }

    @Test("访达按钮揭示本地文件")
    func revealInFinder() async {
        let file = URL(filePath: "/tmp/novpool-local.txt")
        let search = SpySearch()
        search.results = [sample(title: "本地", fileURL: file)]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.revealSelectionInFinder()
        #expect(actions.revealedFiles == [file])
    }

    @Test("预览按钮触发 Quick Look")
    func quickLookSelection() async {
        let file = URL(filePath: "/tmp/novpool-preview.png")
        let search = SpySearch()
        search.results = [sample(title: "图片", fileURL: file)]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.quickLookSelection()
        #expect(actions.quickLookedFiles == [file])
    }
}

@Suite("检索面板布局与快捷键规格")
struct SearchPanelLayoutTests {
    @Test("面板水平居中，垂直略高于屏幕中心，且完整落在可见区域内")
    func placement() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let origin = SearchPanelPlacement.origin(in: visible)
        let frame = NSRect(origin: origin, size: SearchPanelLayout.contentSize)

        #expect(frame.midX == visible.midX)
        #expect(visible.contains(frame))
        #expect(frame.midY > visible.midY)
    }

    @Test("多显示器：按鼠标所在屏幕弹出，找不到则退回首屏")
    func screenSelection() {
        let primary = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let secondary = NSRect(x: 1512, y: 0, width: 1280, height: 800)
        let frames = [primary, secondary]

        #expect(SearchPanelPlacement.screenIndex(containing: NSPoint(x: 100, y: 100), frames: frames) == 0)
        #expect(SearchPanelPlacement.screenIndex(containing: NSPoint(x: 1800, y: 300), frames: frames) == 1)
        #expect(SearchPanelPlacement.screenIndex(containing: NSPoint(x: -500, y: -500), frames: frames) == 0)
        #expect(SearchPanelPlacement.screenIndex(containing: .zero, frames: []) == nil)
    }

    @Test("快捷键解析：默认组合、别名、顺序无关、非法输入")
    func hotKeyParsing() {
        let spec = HotKeySpec(named: "cmd+shift+space")
        #expect(spec?.keyCode == HotKeySpec.default.keyCode)
        #expect(spec?.carbonModifiers == HotKeySpec.default.carbonModifiers)
        #expect(spec?.displayName == "⇧⌘Space")

        #expect(HotKeySpec(named: "shift+cmd+k") == HotKeySpec(named: "command+shift+k"))
        #expect(HotKeySpec(named: "⌥+space")?.displayName == "⌥Space")
        #expect(HotKeySpec(named: "ctrl+alt+a")?.carbonModifiers == UInt32(controlKey | optionKey))

        #expect(HotKeySpec(named: "space") == nil)          // 缺少修饰键
        #expect(HotKeySpec(named: "cmd+shift") == nil)      // 缺少主键
        #expect(HotKeySpec(named: "cmd+unknown") == nil)    // 无法识别的键名
        #expect(HotKeySpec(named: "") == nil)
    }
}
