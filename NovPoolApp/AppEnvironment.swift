import AppKit
import Foundation
import NovPoolConnectors
import NovPoolCore
import NovPoolStorage
import NovPoolSystemBridge
import NovPoolUI

/// 应用装配根：数据库、Staging、溯源、路由与悬浮窗都在这里接线。
@MainActor
final class AppEnvironment {
    let database: NovPoolDatabase
    let staging: StagingStore
    let orchestrator: IngestionOrchestrator
    let connectorRepository: ConnectorRepository
    let outboxWorker: OutboxSyncWorker
    let settingsStore: AppSettingsStore
    let panelController: PanelController
    let globalDragMonitor: GlobalDragMonitor
    let searchPanelController: SearchPanelController
    let dataDirectory: URL

    private(set) var statusSummary: String = "就绪"

    private init(
        database: NovPoolDatabase,
        staging: StagingStore,
        orchestrator: IngestionOrchestrator,
        connectorRepository: ConnectorRepository,
        outboxWorker: OutboxSyncWorker,
        settingsStore: AppSettingsStore,
        panelController: PanelController,
        globalDragMonitor: GlobalDragMonitor,
        searchPanelController: SearchPanelController,
        dataDirectory: URL
    ) {
        self.database = database
        self.staging = staging
        self.orchestrator = orchestrator
        self.connectorRepository = connectorRepository
        self.outboxWorker = outboxWorker
        self.settingsStore = settingsStore
        self.panelController = panelController
        self.globalDragMonitor = globalDragMonitor
        self.searchPanelController = searchPanelController
        self.dataDirectory = dataDirectory
    }

    static func bootstrap() async throws -> AppEnvironment {
        let settings = NovPoolSettings.load()
        // 首次启动必须先把数据目录建出来：SQLite 不会替数据库文件创建父目录。
        let dataDirectory = try NovPoolPaths.prepareApplicationSupport()
        NovPoolLog.write("数据目录：\(dataDirectory.path(percentEncoded: false))")

        let database = try NovPoolDatabase(
            path: NovPoolPaths.databaseURL().path(percentEncoded: false)
        )
        try await SchemaMigrator.migrate(database)
        NovPoolLog.write("数据库就绪：\(try NovPoolPaths.databaseURL().path(percentEncoded: false))")

        let staging = try StagingStore(root: NovPoolPaths.stagingRoot())
        NovPoolLog.write("暂存目录就绪：\(staging.root.path(percentEncoded: false))")
        let connectorRepository = ConnectorRepository(database: database)

        // Phase 3：连接器中枢 + 事务性发件箱工作器（多云推送与跨云级联）。
        let connectorHub = ConnectorHub(repository: connectorRepository)
        let outboxWorker = OutboxSyncWorker(
            database: database,
            connectors: connectorHub,
            staging: staging,
            configuration: .init(isEnabled: settings.isSyncEnabled)
        )
        await outboxWorker.addObserver { event in
            let detail = event.message.map { "（\($0)）" } ?? ""
            NovPoolLog.write("同步 \(event.outcome.rawValue)：\(event.connectorID)\(detail)")
        }

        // Phase 2 补齐流水线：端侧 OCR + 网页正文提取 + AI 结构化增强与向量化。
        let aiService = AIEnhancementService(
            completer: settings.makeCompleter(),
            embedder: settings.makeEmbedder(),
            configuration: .init(isEnabled: settings.isAIEnabled, categories: settings.categories)
        )
        let enrichmentPipeline = EnrichmentPipeline(
            ocr: VisionOCRService(),
            fetcher: WebContentFetcher(),
            ai: aiService,
            staging: staging,
            configuration: .init(categories: settings.categories)
        )
        let orchestrator = IngestionOrchestrator(
            database: database,
            staging: staging,
            browserContext: BrowserContextExtractor(),
            routeEvaluator: settings.routeEvaluator,
            enricher: enrichmentPipeline
        )

        // 用一个小容器解决「回调要引用自身」的问题：handler 在 viewModel 之前构造，
        // 通过容器在稍后拿到它，从而把后台补齐结果回写到悬浮窗。
        let feedback = CaptureFeedbackBox()
        NovPoolLog.write("开始构造悬浮窗视图…")
        // 槽位来自设置面板（最多四个），用户没配置过时用内置默认值。
        let viewModel = CaptureViewModel(zones: settings.zones) { content, zone in
            let result = try await orchestrator.ingest(content, forcedZone: zone)
            // 按路由决策写入发件箱；真正的推送与跨云级联由工作器在后台完成。
            if !result.routeDecision.connectorIDs.isEmpty {
                _ = try? await outboxWorker.enqueue(
                    itemID: result.record.id,
                    connectorIDs: result.routeDecision.connectorIDs
                )
            }
            // 补齐在后台跑：先让悬浮窗立刻给出「已收录」反馈，OCR / 正文 / AI 完成后
            // 再回写第二条状态提示，拖拽主流程全程不被阻塞。
            let itemID = result.record.id
            let itemTitle = result.record.title
            Task { [orchestrator, feedback] in
                guard let enrichment = await orchestrator.enrichAfterIngest(itemID: itemID) else { return }
                await MainActor.run {
                    feedback.viewModel?.showTransientStatus("已补齐 \(enrichment.summaryLine)：\(itemTitle)")
                }
            }
            return CaptureOutcome(
                title: itemTitle,
                isDuplicate: result.isDuplicate,
                routeTargets: result.routeDecision.connectorIDs
            )
        }
        feedback.viewModel = viewModel
        NovPoolLog.write("悬浮窗视图模型构造完成")
        let panelController = PanelController(viewModel: viewModel)
        // 全局拖拽兜底：部分浏览器不把拖拽事件递给我们的窗口，靠全局鼠标事件兜住。
        let globalDragMonitor = GlobalDragMonitor()
        globalDragMonitor.target = panelController
        globalDragMonitor.logger = { NovPoolDiagnostics.log($0) }
        NovPoolLog.write("悬浮窗控制器构造完成")

        // 检索面板：FTS5 全文 + vDSP 向量相似度，RRF 融合。向量通道复用同一套 embedding 配置。
        let repository = KnowledgeRepository(database: database)
        let searchService = KnowledgeSearchService(
            repository: repository,
            staging: staging,
            embedder: settings.makeEmbedder()
        )
        NovPoolLog.write("检索服务构造完成")
        let searchPanelController = SearchPanelController(
            search: { query in
                try await searchService.search(query, limit: 40)
            },
            hotKeySpec: settings.searchHotKey
        )
        NovPoolLog.write("检索面板构造完成（快捷键注册=\(searchPanelController.isHotKeyRegistered)）")

        let itemCount = try await repository.count()
        NovPoolLog.write("启动收尾：已收录 \(itemCount) 条")
        let settingsStore = AppSettingsStore(
            connectorRepository: connectorRepository,
            database: database
        )
        let environment = AppEnvironment(
            database: database,
            staging: staging,
            orchestrator: orchestrator,
            connectorRepository: connectorRepository,
            outboxWorker: outboxWorker,
            settingsStore: settingsStore,
            panelController: panelController,
            globalDragMonitor: globalDragMonitor,
            searchPanelController: searchPanelController,
            dataDirectory: dataDirectory
        )
        let hotKeyLabel = settings.searchHotKey.displayName
        environment.statusSummary = searchPanelController.isHotKeyRegistered
            ? "已收录 \(itemCount) 条 · 拖拽归档 · \(hotKeyLabel) 搜索"
            : "已收录 \(itemCount) 条 · 快捷键被占用，请从菜单打开搜索"
        environment.wireGlobalDragCapture(viewModel: viewModel)
        return environment
    }

    func start() {
        panelController.show()
        Task { await outboxWorker.start() }
        globalDragMonitor.start()
        Task { await backfillMissingFileContent() }
        let frame = panelController.panel.frame
        NovPoolLog.write(
            "悬浮窗已显示：visible=\(panelController.panel.isVisible) "
                + "frame=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))) "
                + "屏幕数=\(NSScreen.screens.count)"
        )
        for (index, screen) in NSScreen.screens.enumerated() {
            NovPoolLog.write("屏幕 \(index) visibleFrame=\(screen.visibleFrame)")
        }
    }

    private func backfillMissingFileContent() async {
        let repository = KnowledgeRepository(database: database)
        guard let records = try? await repository.recordsNeedingLocalFileContent(limit: 100),
              !records.isEmpty else {
            return
        }
        var filled = 0
        for record in records {
            if await orchestrator.enrichAfterIngest(itemID: record.id) != nil {
                filled += 1
            }
        }
        NovPoolLog.write("本机文件正文回填：完成 \(filled)/\(records.count) 条")
    }

    func toggleSearchPanel() {
        searchPanelController.toggle()
    }

    /// 设置面板里的「立即同步一轮」。
    func runSyncNow() async -> String {
        let result = await outboxWorker.runOnce()
        return "本轮处理 \(result.processed) 条：成功 \(result.succeeded)、失败 \(result.failed)、"
            + "等待前置 \(result.waiting)、解锁下游 \(result.released)"
    }

    // MARK: - 全局拖拽兜底

    /// 松手落在悬浮图标上时，绕开拖拽事件直接抓取内容：
    /// 1) 辅助功能读取选中文字；2) 浏览器活跃标签（URL + 标题）；3) 通用粘贴板。
    func wireGlobalDragCapture(viewModel: CaptureViewModel) {
        globalDragMonitor.onDrop = { [weak viewModel] in
            Task { @MainActor in
                guard let viewModel else { return }
                await self.captureFromFallback(into: viewModel)
            }
        }
    }

    private func captureFromFallback(into viewModel: CaptureViewModel) async {
        let selection = AXSelectionReader().selectedText()
        if let selection, !selection.isEmpty {
            NovPoolDiagnostics.log("全局兜底：抓到选中文字（\(selection.count) 字）")
            viewModel.handleDrop(
                ResolvedDragContent(contentType: .plainText, text: selection),
                zoneIndex: nil
            )
            return
        }

        // 兜底路径是用户手动触发，放宽溯源超时：首次调用会弹「自动化」授权框，
        // 150ms 根本来不及授权，所以这里给 2 秒。
        let extractor = BrowserContextExtractor()
        let context = await extractor.captureContext(now: Date(), timeout: .seconds(2))
        if let url = context.pageURL {
            // 标签指向本机文件（file://）：直接把文件本身归档，而不是只记一条链接。
            if url.isFileURL, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                NovPoolDiagnostics.log("全局兜底：抓取本地文件 \(url.lastPathComponent)")
                viewModel.handleDrop(
                    ResolvedDragContent(
                        contentType: FileKind.of(url: url).contentType,
                        fileURLs: [url],
                        linkTitle: context.pageTitle
                    ),
                    zoneIndex: nil
                )
                return
            }
            NovPoolDiagnostics.log("全局兜底：抓到浏览器标签 \(url.absoluteString)")
            viewModel.handleDrop(
                ResolvedDragContent(
                    contentType: .webLink,
                    pageURL: url,
                    linkTitle: context.pageTitle
                ),
                zoneIndex: nil
            )
            return
        }

        if let content = PasteboardResolver().resolve(from: NSPasteboardReader()) {
            NovPoolDiagnostics.log("全局兜底：使用通用粘贴板（\(content.contentType.rawValue)）")
            viewModel.handleDrop(content, zoneIndex: nil)
        } else {
            NovPoolDiagnostics.log(
                "全局兜底：没有可抓取的内容（前台=\(context.appBundleID)；"
                    + "若这是浏览器，请在「系统设置 → 隐私与安全性 → 自动化」里允许 NovPool 控制它）"
            )
            viewModel.showTransientStatus("没有识别到可保存的内容", isError: true)
        }
    }

    func showPanel() {
        panelController.show()
    }

    func hidePanel() {
        panelController.hide()
    }

    /// 把悬浮图标送回默认右下角（并清除记住的位置）。
    func resetPanelPosition() {
        panelController.resetPosition()
    }

    func revealDataDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDirectory])
    }

    /// Phase 3 会把路由目标换成真实连接器配置；当前先指向 Staging 归档目录。
    func revealArchiveDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([staging.root])
    }
}

/// 仅在主线程上传递悬浮窗状态模型的容器。
@MainActor
final class CaptureFeedbackBox {
    /// 弱引用：避免 box → viewModel → handler → box 的强引用环。
    weak var viewModel: CaptureViewModel?
}
