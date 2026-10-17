import AppKit
import CoreGraphics
import CoreText
import Foundation
import NovPoolCore
import NovPoolConnectors
import NovPoolStorage
import NovPoolSystemBridge

/// 无界面自检。
///
/// 用途：不开 GUI 就能验证「数据目录 → 建库 → 暂存 → 入库 → 补齐 → 检索」这条真实链路，
/// 一条命令暴露的环境问题（目录不可写、SQLite 不可用、ANE 不可用）当场可见：
///
///     ./build/NovPool.app/Contents/MacOS/NovPool --selftest
///
/// 自检会往正式知识库里写入一条标题为「NovPool 自检条目」的记录，方便随后在检索面板里找到它。
enum SelfTest {
    static func run() -> Int32 {
        let box = ExitBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.code = await perform()
            semaphore.signal()
        }
        semaphore.wait()
        return box.code
    }

    private final class ExitBox: @unchecked Sendable {
        var code: Int32 = 1
    }

    private struct FixedBrowserContext: BrowserContextProviding {
        let context: SourceContext
        func captureContext() async -> SourceContext { context }
    }

    private static func perform() async -> Int32 {
        var failures = 0

        func report(_ label: String, _ passed: Bool, _ detail: String = "") {
            let mark = passed ? "✓" : "✗"
            print("\(mark) \(label)\(detail.isEmpty ? "" : "：\(detail)")")
            if !passed { failures += 1 }
        }

        print("NovPool 自检开始（macOS \(ProcessInfo.processInfo.operatingSystemVersionString)）")
        print("日志文件：\(NovPoolLog.path)")

        // 1. 数据目录（首次启动最容易崩在这里）
        let dataDirectory: URL
        do {
            dataDirectory = try NovPoolPaths.prepareApplicationSupport()
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: dataDirectory.path(percentEncoded: false),
                isDirectory: &isDirectory
            )
            report("数据目录可写", exists && isDirectory.boolValue, dataDirectory.path(percentEncoded: false))
        } catch {
            report("数据目录可写", false, "\(error)")
            print("自检中止：数据目录不可用，后续步骤无意义。")
            return 1
        }

        // 2. 建库与迁移
        let databaseURL = try? NovPoolPaths.databaseURL()
        guard let databaseURL else {
            report("数据库", false, "无法解析数据库路径")
            return 1
        }
        let database: NovPoolDatabase
        do {
            database = try NovPoolDatabase(path: databaseURL.path(percentEncoded: false))
            try await SchemaMigrator.migrate(database)
            let itemCount = try await KnowledgeRepository(database: database).count()
            report("数据库可写（现有 \(itemCount) 条）", true, databaseURL.path(percentEncoded: false))
        } catch {
            report("数据库可写", false, "\(error)")
            return 1
        }

        // 3. 暂存
        let staging: StagingStore
        let imageData: Data
        do {
            staging = try StagingStore(root: NovPoolPaths.stagingRoot())
            guard let png = makeSampleImage(text: "NovPool 自检 \(Date().formatted(date: .numeric, time: .standard))") else {
                report("暂存目录", false, "无法生成测试图片")
                return 1
            }
            imageData = png
            let asset = try await staging.stage(data: png, preferredExtension: "png")
            let onDisk = FileManager.default.fileExists(atPath: asset.absoluteURL.path(percentEncoded: false))
            report("暂存写入", onDisk && asset.sha256.count == 64, asset.relativePath)
        } catch {
            report("暂存写入", false, "\(error)")
            return 1
        }

        // 4. 入库
        let repository = KnowledgeRepository(database: database)
        // 标题由溯源上下文决定：给一个确定性的 pageTitle，自检才好断言、用户也好搜索。
        let selfTestTitle = "NovPool 自检条目"
        let orchestrator = IngestionOrchestrator(
            database: database,
            staging: staging,
            browserContext: FixedBrowserContext(
                context: SourceContext(
                    appBundleID: "com.novpool.selftest",
                    pageURL: URL(string: "https://example.com/novpool-selftest"),
                    pageTitle: selfTestTitle
                )
            ),
            enricher: EnrichmentPipeline(
                ocr: VisionOCRService(),
                fetcher: WebContentFetcher(),
                ai: AIEnhancementService(completer: nil, embedder: nil)
            )
        )

        let itemID: UUID
        do {
            let result = try await orchestrator.ingest(
                ResolvedDragContent(
                    contentType: .image,
                    imageData: imageData,
                    imageTypeIdentifier: "public.png"
                ),
                sourceContext: SourceContext(
                    appBundleID: "com.novpool.selftest",
                    pageURL: URL(string: "https://example.com/novpool-selftest"),
                    pageTitle: selfTestTitle
                )
            )
            itemID = result.record.id
            report("拖拽入库", result.record.title.isEmpty == false, "title=\(result.record.title) 暂存=\(result.record.localRelativePath ?? "无")")
        } catch {
            report("拖拽入库", false, "\(error)")
            return 1
        }

        // 5. 补齐（OCR 依赖系统 ANE 服务，不可用时跳过而非判失败）
        let enrichment = await orchestrator.enrichAfterIngest(itemID: itemID)
        if let enrichment {
            report("后台补齐", true, enrichment.summaryLine)
        } else {
            print("· 后台补齐：本次没有产出（OCR 需要系统 ANE 服务；纯文本/网页条目则取决于网络与 AI 配置）")
        }

        // 6. 检索：全文 + 混合
        do {
            let search = KnowledgeSearchService(repository: repository, staging: staging, embedder: nil)
            let hits = try await search.search(selfTestTitle)
            let found = hits.contains { $0.title == selfTestTitle }
            report(
                "全文检索命中",
                found,
                found ? "返回 \(hits.count) 条" : "返回 \(hits.count) 条：\(hits.map(\.title).joined(separator: " / "))"
            )

            let recent = try await search.recent(limit: 5)
            report("最近条目列表", !recent.isEmpty, "\(recent.count) 条")
        } catch {
            report("全文检索命中", false, "\(error)")
        }

        // 7. 云同步链路：连接器中枢 + 发件箱工作器（本地挂载连接器可离线验证）
        //    同时验证跨云级联：第二个任务依赖第一个，只有前者成功后才执行。
        do {
            let connectorRepository = ConnectorRepository(database: database)
            let firstRoot = dataDirectory.appending(path: "SelfTestArchiveA", directoryHint: .isDirectory)
            let secondRoot = dataDirectory.appending(path: "SelfTestArchiveB", directoryHint: .isDirectory)
            try NovPoolPaths.ensureDirectory(at: firstRoot)
            try NovPoolPaths.ensureDirectory(at: secondRoot)

            func configJSON(root: URL) throws -> String {
                let data = try JSONSerialization.data(withJSONObject: [
                    "namingTemplate": "{Category}/{Title}.{ext}",
                    "rootPath": root.path(percentEncoded: false),
                ])
                return String(decoding: data, as: UTF8.self)
            }

            try await connectorRepository.upsert(ConnectorRecord(
                id: "selftest-a",
                name: "自检归档 A",
                connectorType: "local_mount",
                configJSON: try configJSON(root: firstRoot)
            ))
            try await connectorRepository.upsert(ConnectorRecord(
                id: "selftest-b",
                name: "自检归档 B",
                connectorType: "local_mount",
                configJSON: try configJSON(root: secondRoot)
            ))

            let worker = OutboxSyncWorker(
                database: database,
                connectors: ConnectorHub(repository: connectorRepository),
                staging: staging
            )
            // 故意把 A 放在后面，检验「按类型排序」确实把文件型连接器排在前面并串成链
            let jobs = try await worker.enqueue(itemID: itemID, connectorIDs: ["selftest-b", "selftest-a"])
            let outbox = OutboxRepository(database: database)
            let chained = try await outbox.fetch(id: jobs[1])?.dependsOnJobID == jobs[0]

            let firstRun = await worker.runOnce()
            let secondRun = await worker.runOnce()
            let records = try await outbox.jobs(forItem: itemID)
            let succeeded = records.filter { $0.status == .succeeded }.count
            let landed = records.compactMap { $0.remoteWebURL.flatMap(URL.init(string:)) }
                .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
                .count

            report(
                "云同步 + 级联",
                chained && firstRun.succeeded == 1 && secondRun.succeeded == 1
                    && succeeded == 2 && landed == 2,
                "级联=\(chained) 首轮成功=\(firstRun.succeeded) 次轮成功=\(secondRun.succeeded) 落盘=\(landed)"
            )
        } catch {
            report("云同步 + 级联", false, "\(error)")
        }

        print("")
        if failures == 0 {
            print("自检通过。可用菜单栏「搜索知识库…」搜索「NovPool 自检条目」确认数据落库。")
            return 0
        }
        print("自检失败 \(failures) 项，详见上方输出与 \(NovPoolLog.path)")
        return 1
    }

    /// 用 CoreText 画一张含文字的位图（不需要 WindowServer）。
    private static func makeSampleImage(text: String) -> Data? {
        let width = 900
        let height = 220
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
        )
        context.textPosition = CGPoint(x: 40, y: 90)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
