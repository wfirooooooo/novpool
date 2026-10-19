import AppKit
import Foundation
import NovPoolConnectors
import NovPoolCore
import NovPoolStorage
import NovPoolSystemBridge
import NovPoolUI

/// App assembly root: database, staging, provenance, routing, and drop zone are wired here.
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
    let aiService: AIEnhancementService
    let enrichmentPipeline: EnrichmentPipeline
    let searchService: KnowledgeSearchService

    private(set) var statusSummary: String = "Ready"

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
        dataDirectory: URL,
        aiService: AIEnhancementService,
        enrichmentPipeline: EnrichmentPipeline,
        searchService: KnowledgeSearchService
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
        self.aiService = aiService
        self.enrichmentPipeline = enrichmentPipeline
        self.searchService = searchService
    }

    static func bootstrap() async throws -> AppEnvironment {
        let settings = NovPoolSettings.load()
        // First launch must create the data directory: SQLite will not create parent dirs for the DB file.
        let dataDirectory = try NovPoolPaths.prepareApplicationSupport()
        NovPoolLog.write("Data directory: \(dataDirectory.path(percentEncoded: false))")

        let database = try NovPoolDatabase(
            path: NovPoolPaths.databaseURL().path(percentEncoded: false)
        )
        try await SchemaMigrator.migrate(database)
        NovPoolLog.write("Database ready: \(try NovPoolPaths.databaseURL().path(percentEncoded: false))")

        let staging = try StagingStore(root: NovPoolPaths.stagingRoot())
        NovPoolLog.write("Staging ready: \(staging.root.path(percentEncoded: false))")
        let connectorRepository = ConnectorRepository(database: database)

        // Phase 3: connector hub + transactional outbox worker (multi-cloud push and cascade).
        let connectorHub = ConnectorHub(repository: connectorRepository)
        let outboxWorker = OutboxSyncWorker(
            database: database,
            connectors: connectorHub,
            staging: staging,
            configuration: .init(isEnabled: settings.isSyncEnabled)
        )
        await outboxWorker.addObserver { event in
            let detail = event.message.map { " (\($0))" } ?? ""
            NovPoolLog.write("Sync \(event.outcome.rawValue): \(event.connectorID)\(detail)")
        }

        // Phase 2 enrichment: on-device OCR + web extract + AI structure / embeddings.
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

        // Small box so the capture handler (built before the view model) can later
        // push background enrichment status back into the drop zone.
        let feedback = CaptureFeedbackBox()
        NovPoolLog.write("Building drop-zone view…")
        // Sectors come from Settings (up to four); fall back to built-in defaults.
        let viewModel = CaptureViewModel(zones: settings.zones) { content, zone in
            let result = try await orchestrator.ingest(content, forcedZone: zone)
            let itemTitle = result.record.title
            // Duplicates: no second enqueue, no enrichment — just “already exists”.
            guard !result.isDuplicate else {
                return CaptureOutcome(
                    title: itemTitle,
                    isDuplicate: true,
                    routeTargets: result.routeDecision.connectorIDs
                )
            }
            // Enqueue from the route decision; real push / cascade runs in the worker.
            if !result.routeDecision.connectorIDs.isEmpty {
                _ = try? await outboxWorker.enqueue(
                    itemID: result.record.id,
                    connectorIDs: result.routeDecision.connectorIDs
                )
            }
            // Enrichment runs in the background: show “saved” immediately, then a second
            // status line when OCR / body / AI finish, without blocking the drop path.
            let itemID = result.record.id
            Task { [orchestrator, feedback] in
                guard let enrichment = await orchestrator.enrichAfterIngest(itemID: itemID) else { return }
                await MainActor.run {
                    feedback.viewModel?.showTransientStatus("Enriched \(enrichment.summaryLine): \(itemTitle)")
                }
            }
            return CaptureOutcome(
                title: itemTitle,
                isDuplicate: false,
                routeTargets: result.routeDecision.connectorIDs
            )
        }
        feedback.viewModel = viewModel
        NovPoolLog.write("Drop-zone view model ready")
        let panelController = PanelController(viewModel: viewModel)
        // Global drag fallback: some browsers never deliver drag events to our window.
        let globalDragMonitor = GlobalDragMonitor()
        globalDragMonitor.target = panelController
        globalDragMonitor.logger = { NovPoolDiagnostics.log($0) }
        NovPoolLog.write("Drop-zone controller ready")

        // Search panel: FTS5 + vDSP similarity, RRF fusion. Embeddings reuse the same config.
        let repository = KnowledgeRepository(database: database)
        let searchService = KnowledgeSearchService(
            repository: repository,
            staging: staging,
            embedder: settings.makeEmbedder()
        )
        NovPoolLog.write("Search service ready")
        let searchPanelController = SearchPanelController(
            search: { query in
                try await searchService.search(query, limit: 40)
            },
            loadCategories: {
                // Settings topic tree + categories already used in the library (tree first).
                let tree = NovPoolSettings.load().categories
                let used = (try? await searchService.distinctCategories()) ?? []
                var ordered: [String] = []
                for name in tree + used where !ordered.contains(name) {
                    ordered.append(name)
                }
                return ordered
            },
            hotKeySpec: settings.searchHotKey,
            actions: SearchPanelController.liveActions(
                deleteItem: { id in
                    try await searchService.deleteItem(id: id)
                },
                updateOrganization: { id, organization in
                    try await searchService.updateOrganization(id: id, organization: organization)
                },
                resummarizeItem: { id in
                    let result = await orchestrator.resummarize(itemID: id)
                    switch result {
                    case .updated:
                        return ResummarizeFeedback(outcome: .updated, message: result.statusMessage)
                    case .failed, .notFound:
                        return ResummarizeFeedback(outcome: .failed, message: result.statusMessage)
                    }
                },
                digestItems: { sources in
                    await aiService.digest(sources)
                },
                saveDigest: { draft in
                    let record = draft.makeRecord()
                    try await repository.insert(record)
                    return record.id
                },
                loadItem: { id in
                    try? await searchService.item(id: id)
                }
            ),
            maxDigestItems: settings.digestMaxItems
        )
        NovPoolLog.write(
            "Search panel ready (hotkey registered=\(searchPanelController.isHotKeyRegistered))"
        )

        let itemCount = try await repository.count()
        NovPoolLog.write("Startup complete: \(itemCount) items")
        let settingsStore = AppSettingsStore(
            connectorRepository: connectorRepository,
            database: database
        )
        settingsStore.resummarizeMissingHandler = {
            await orchestrator.resummarizeMissingSummaries(limit: 20).statusMessage
        }
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
            dataDirectory: dataDirectory,
            aiService: aiService,
            enrichmentPipeline: enrichmentPipeline,
            searchService: searchService
        )
        settingsStore.applyRuntimeHandler = { [weak environment] in
            guard let environment else { return "Environment not ready" }
            return await environment.applyRuntimeSettings()
        }
        let hotKeyLabel = settings.searchHotKey.displayName
        environment.statusSummary = searchPanelController.isHotKeyRegistered
            ? "\(itemCount) items · drop on icon to save · \(hotKeyLabel) to search"
            : "\(itemCount) items · hotkey in use; open search from the menu"
        environment.wireGlobalDragCapture(viewModel: viewModel)
        return environment
    }

    /// Hot-apply after Settings save: hotkey, sectors, routes, sync toggle, AI models.
    @discardableResult
    func applyRuntimeSettings() async -> String {
        let settings = NovPoolSettings.load()
        await orchestrator.update(routeEvaluator: settings.routeEvaluator)
        panelController.updateZones(settings.zones)
        let hotKeyOK = searchPanelController.updateHotKey(settings.searchHotKey)
        searchPanelController.updateDigestLimit(settings.digestMaxItems)
        await outboxWorker.update(configuration: .init(isEnabled: settings.isSyncEnabled))
        await enrichmentPipeline.update(
            configuration: .init(categories: settings.categories)
        )
        let completer = settings.makeCompleter()
        let embedder = settings.makeEmbedder()
        await aiService.updateProviders(
            completer: completer,
            embedder: embedder,
            configuration: .init(isEnabled: settings.isAIEnabled, categories: settings.categories)
        )
        await searchService.update(embedder: embedder)

        let itemCount = (try? await KnowledgeRepository(database: database).count()) ?? 0
        let hotKeyLabel = settings.searchHotKey.displayName
        statusSummary = hotKeyOK
            ? "\(itemCount) items · drop on icon to save · \(hotKeyLabel) to search"
            : "\(itemCount) items · hotkey in use; open search from the menu"
        if hotKeyOK {
            return "Saved and applied"
        }
        return "Saved; hotkey was not accepted — pick another or open search from the menu"
    }

    func start() {
        panelController.show()
        Task { await outboxWorker.start() }
        globalDragMonitor.start()
        Task { await backfillMissingFileContent() }
        let frame = panelController.panel.frame
        NovPoolLog.write(
            "Drop zone shown: visible=\(panelController.panel.isVisible) "
                + "frame=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))) "
                + "screens=\(NSScreen.screens.count)"
        )
        for (index, screen) in NSScreen.screens.enumerated() {
            NovPoolLog.write("Screen \(index) visibleFrame=\(screen.visibleFrame)")
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
        NovPoolLog.write("Local file body backfill: \(filled)/\(records.count) items")
    }

    func toggleSearchPanel() {
        searchPanelController.toggle()
    }

    /// Settings “Sync now” action.
    func runSyncNow() async -> String {
        let result = await outboxWorker.runOnce()
        return "Processed \(result.processed): succeeded \(result.succeeded), failed \(result.failed), "
            + "waiting \(result.waiting), unlocked downstream \(result.released)"
    }

    // MARK: - Global drag fallback

    /// Fallback path when the user releases over the floating icon.
    /// Prefer the drag pasteboard; suppress when native `NSDraggingDestination` already handled the drop.
    func wireGlobalDragCapture(viewModel: CaptureViewModel) {
        let coordinator = panelController.dragCoordinator
        globalDragMonitor.shouldAcceptDrop = {
            !coordinator.shouldSuppressFallback
        }
        globalDragMonitor.onDrop = { [weak viewModel] in
            Task { @MainActor in
                guard let viewModel else { return }
                await self.captureFromFallback(into: viewModel)
            }
        }
    }

    private func captureFromFallback(into viewModel: CaptureViewModel) async {
        // User-triggered fallback: allow a longer provenance timeout. The first call may
        // show the Automation prompt; 150ms is not enough, so use 2 seconds here.
        let extractor = BrowserContextExtractor()
        let context = await extractor.captureContext(now: Date(), timeout: .seconds(2))
        let pageURL = context.pageURL
        let fileExists = pageURL.map {
            $0.isFileURL && FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        } ?? false

        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: NSPasteboardReader(pasteboard: NSPasteboard(name: .drag)),
            generalPasteboard: NSPasteboardReader(pasteboard: .general),
            browser: .init(
                pageURL: pageURL,
                pageTitle: context.pageTitle,
                fileExistsAtPageURL: fileExists
            ),
            selectedText: AXSelectionReader().selectedText()
        )

        guard let decision else {
            NovPoolDiagnostics.log(
                "Global fallback: nothing to capture (frontmost=\(context.appBundleID); "
                    + "if this is a browser, allow NovPool under System Settings → Privacy & Security → Automation)"
            )
            viewModel.showTransientStatus("Nothing recognizable to save", isError: true)
            return
        }

        NovPoolDiagnostics.log(
            "Global fallback: source=\(decision.source) type=\(decision.content.contentType.rawValue)"
        )
        viewModel.handleDrop(decision.content, zoneIndex: nil)
    }

    func showPanel() {
        panelController.show()
    }

    func hidePanel() {
        panelController.hide()
    }

    /// Move the floating icon back to the default bottom-right (and clear the remembered position).
    func resetPanelPosition() {
        panelController.resetPosition()
    }

    func revealDataDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDirectory])
    }

    /// Phase 3 will point this at real connector roots; for now reveal the staging archive.
    func revealArchiveDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([staging.root])
    }
}

/// Main-actor box that hands the drop-zone view model to late callbacks.
@MainActor
final class CaptureFeedbackBox {
    /// Weak to avoid box → viewModel → handler → box retain cycles.
    weak var viewModel: CaptureViewModel?
}
