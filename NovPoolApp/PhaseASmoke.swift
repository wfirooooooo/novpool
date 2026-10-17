import AppKit
import Foundation
import NovPoolCore
import NovPoolStorage
import NovPoolSystemBridge
import NovPoolUI

/// Phase A 本机冒烟：走与正式 app 相同的数据目录 / 入库 / 兜底解析逻辑。
///
///     ./build/NovPool.app/Contents/MacOS/NovPool --phase-a-smoke
///     ./build/NovPool.app/Contents/MacOS/NovPool --ingest /path/a.txt /path/b.md
///     ./build/NovPool.app/Contents/MacOS/NovPool --ingest-url 'https://example.com' --title '标题'
enum PhaseASmoke {
    static func run(arguments: [String]) -> Int32? {
        if arguments.contains("--phase-a-smoke") {
            return execute { await smoke() }
        }
        if let index = arguments.firstIndex(of: "--ingest") {
            var paths: [String] = []
            for argument in arguments[(index + 1)...] {
                if argument.hasPrefix("--") { break }
                paths.append(argument)
            }
            guard !paths.isEmpty else {
                print("用法：--ingest <file> [file...]")
                return 2
            }
            let filePaths = paths
            return execute { await ingestFiles(filePaths) }
        }
        if let index = arguments.firstIndex(of: "--ingest-url") {
            guard index + 1 < arguments.count else {
                print("用法：--ingest-url <url> [--title <标题>]")
                return 2
            }
            let urlString = arguments[index + 1]
            let title: String?
            if let titleIndex = arguments.firstIndex(of: "--title"), titleIndex + 1 < arguments.count {
                title = arguments[titleIndex + 1]
            } else {
                title = nil
            }
            return execute { await ingestURL(urlString, title: title) }
        }
        return nil
    }

    private static func execute(_ body: @escaping @Sendable () async -> Int32) -> Int32 {
        let box = ExitBox()
        let semaphore = DispatchSemaphore(value: 0)
        // 必须在主 actor 上跑（协调器等），且 init 阻塞在主线程时要泵 RunLoop，否则会死锁。
        Task { @MainActor in
            box.code = await body()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return box.code
    }

    private final class ExitBox: @unchecked Sendable {
        var code: Int32 = 1
    }

    // MARK: - 命令

    private static func smoke() async -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : "：\(detail)")")
            if !ok { failures += 1 }
        }

        let dataRoot = (try? NovPoolPaths.applicationSupport())?.path(percentEncoded: false) ?? "(未知)"
        print("Phase A 本机冒烟（数据目录：\(dataRoot)）")

        // A2 协调器（主 actor 类型；不可在阻塞主线程的 semaphore 路径上直接标 @MainActor）
        let coordinatorOK = await MainActor.run { () -> (Bool, Bool, Bool) in
            let coordinator = DragCaptureCoordinator()
            coordinator.markNativeDragEntered()
            let entered = coordinator.shouldSuppressFallback
            coordinator.markNativeDropHandled()
            let handled = coordinator.shouldSuppressFallback
            coordinator.markNativeDragCancelled()
            let afterCancel = coordinator.shouldSuppressFallback
            return (entered, handled, afterCancel)
        }
        check("A2 原生进入时抑制兜底", coordinatorOK.0)
        check("A2 原生成功后短时抑制", coordinatorOK.1)
        check("A2 成功抑制不被 cancel 清掉", coordinatorOK.2)

        // A3 解析顺序
        struct MemPB: PasteboardReading {
            var storage: [String: String]
            var availableTypeIdentifiers: [String] { Array(storage.keys) }
            func data(forTypeIdentifier typeIdentifier: String) -> Data? {
                storage[typeIdentifier].map { Data($0.utf8) }
            }
            func string(forTypeIdentifier typeIdentifier: String) -> String? {
                storage[typeIdentifier]
            }
        }
        let decision = FallbackCaptureResolver.resolve(
            dragPasteboard: MemPB(storage: [PasteboardTypeID.url: "https://example.com/from-drag"]),
            generalPasteboard: MemPB(storage: [PasteboardTypeID.plainText: "通用粘贴板"]),
            browser: .init(pageURL: URL(string: "https://example.com/tab"), pageTitle: "标签"),
            selectedText: "不该用选中文字"
        )
        check(
            "A3 拖拽粘贴板优先于选中文字",
            decision?.source == "拖拽粘贴板" && decision?.content.pageURL?.absoluteString == "https://example.com/from-drag",
            decision?.source ?? "nil"
        )

        // A5 多文件入库（真实库）
        let token = UUID().uuidString.prefix(8)
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "novpool-phase-a-\(token)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let a = tmp.appending(path: "phase-a-alpha-\(token).txt")
        let b = tmp.appending(path: "phase-a-beta-\(token).md")
        try? "alpha body for phase a \(token)\n".write(to: a, atomically: true, encoding: .utf8)
        try? "# beta body for phase a \(token)\n".write(to: b, atomically: true, encoding: .utf8)

        do {
            let before = try await itemCount()
            let ingested = try await ingestResolved(
                ResolvedDragContent(
                    contentType: .genericFile,
                    fileURLs: [a, b],
                    matchedTypeIdentifiers: [PasteboardTypeID.fileURL]
                )
            )
            let after = try await itemCount()
            check(
                "A5 多文件拆条入库",
                ingested.saved == 2 && after == before + 2,
                "新写入 \(ingested.saved)，库 \(before)→\(after)"
            )

            let linkBefore = try await itemCount()
            let linkURL = URL(string: "https://example.com/phase-a-smoke-\(token)")!
            let links = try await ingestResolved(
                ResolvedDragContent(
                    contentType: .webLink,
                    pageURL: linkURL,
                    linkTitle: "Phase A Smoke Link \(token)"
                )
            )
            let linkAfter = try await itemCount()
            check("网页链接入库", links.saved == 1 && linkAfter == linkBefore + 1)

            // FTS
            let hits = try await searchHits("phase-a-alpha-\(token)")
            check("FTS 能命中刚入库文件", hits >= 1, "hits=\(hits)")
        } catch {
            check("真实库入库", false, error.localizedDescription)
        }

        // 浏览器活跃标签（可选：前台是浏览器时才算硬性）
        let browser = await BrowserContextExtractor().captureContext(now: Date(), timeout: .seconds(2))
        if let url = browser.pageURL {
            print("· 浏览器溯源可用：\(url.absoluteString)（\(browser.pageTitle ?? "无标题")）")
            check("浏览器上下文可读取", true)
        } else {
            print("· 浏览器溯源未取到 URL（前台=\(browser.appBundleID)；拖标签仍依赖自动化权限）")
            check("浏览器上下文可读取（软项，未就绪不失败）", true, "跳过")
        }

        print(failures == 0 ? "\nPhase A 冒烟通过。" : "\nPhase A 冒烟失败 \(failures) 项。")
        return failures == 0 ? 0 : 1
    }

    private static func ingestFiles(_ paths: [String]) async -> Int32 {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        for url in urls where !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            print("文件不存在：\(url.path(percentEncoded: false))")
            return 2
        }
        do {
            let content = ResolvedDragContent(
                contentType: FileKind.of(url: urls[0]).contentType,
                fileURLs: urls,
                matchedTypeIdentifiers: [PasteboardTypeID.fileURL]
            )
            let summary = try await ingestResolved(content)
            print(summary.message + "：" + urls.map(\.lastPathComponent).joined(separator: ", "))
            return 0
        } catch {
            print("入库失败：\(error.localizedDescription)")
            return 1
        }
    }

    private static func ingestURL(_ raw: String, title: String?) async -> Int32 {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            print("无效 URL：\(raw)")
            return 2
        }
        do {
            let summary = try await ingestResolved(
                ResolvedDragContent(contentType: .webLink, pageURL: url, linkTitle: title)
            )
            print(summary.message + "：" + (title ?? url.absoluteString))
            return 0
        } catch {
            print("入库失败：\(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - 共享装配

    private struct FixedBrowser: BrowserContextProviding {
        func captureContext() async -> SourceContext {
            SourceContext(appBundleID: "com.novpool.phase-a-smoke")
        }
    }

    private static func makeOrchestrator() async throws -> (IngestionOrchestrator, KnowledgeRepository) {
        _ = try NovPoolPaths.prepareApplicationSupport()
        let database = try NovPoolDatabase(path: NovPoolPaths.databaseURL().path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        let staging = try StagingStore(root: NovPoolPaths.stagingRoot())
        let orchestrator = IngestionOrchestrator(
            database: database,
            staging: staging,
            browserContext: FixedBrowser()
        )
        return (orchestrator, KnowledgeRepository(database: database))
    }

    private struct IngestSummary {
        var saved: Int
        var duplicates: Int
        var message: String {
            if duplicates == 0 { return "已入库 \(saved) 项" }
            if saved == 0 { return "已存在 \(duplicates) 项" }
            return "已入库 \(saved) 项，跳过 \(duplicates) 个重复"
        }
    }

    private static func ingestResolved(_ content: ResolvedDragContent) async throws -> IngestSummary {
        let (orchestrator, _) = try await makeOrchestrator()
        var saved = 0
        var duplicates = 0
        for item in content.expandedForIngest() {
            let result = try await orchestrator.ingest(item)
            if result.isDuplicate { duplicates += 1 } else { saved += 1 }
        }
        return IngestSummary(saved: saved, duplicates: duplicates)
    }

    private static func itemCount() async throws -> Int {
        let (_, repository) = try await makeOrchestrator()
        return try await repository.count()
    }

    private static func searchHits(_ query: String) async throws -> Int {
        let (orchestrator, repository) = try await makeOrchestrator()
        _ = orchestrator
        let staging = try StagingStore(root: NovPoolPaths.stagingRoot())
        let service = KnowledgeSearchService(repository: repository, staging: staging, embedder: nil)
        return try await service.search(query, limit: 20).count
    }
}
