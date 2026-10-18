import AppKit
import CoreGraphics
import CoreText
import Foundation
import NovPoolCore
import NovPoolConnectors
import NovPoolStorage
import NovPoolSystemBridge

/// Headless self-test.
///
/// Verifies the real path “data dir → DB → staging → ingest → enrich → search”
/// without opening the GUI, so environment issues (unwritable dir, SQLite, ANE)
/// show up in one command:
///
///     ./build/NovPool.app/Contents/MacOS/NovPool --selftest
///
/// Writes a library item titled “NovPool Self-Test Item” so you can find it in Search.
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
            print("\(mark) \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            if !passed { failures += 1 }
        }

        print("NovPool self-test starting (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        print("Log file: \(NovPoolLog.path)")

        // 1. Data directory (most common first-launch crash)
        let dataDirectory: URL
        do {
            dataDirectory = try NovPoolPaths.prepareApplicationSupport()
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: dataDirectory.path(percentEncoded: false),
                isDirectory: &isDirectory
            )
            report("Data directory writable", exists && isDirectory.boolValue, dataDirectory.path(percentEncoded: false))
        } catch {
            report("Data directory writable", false, "\(error)")
            print("Self-test aborted: data directory unavailable; later steps are meaningless.")
            return 1
        }

        // 2. Database + migration
        let databaseURL = try? NovPoolPaths.databaseURL()
        guard let databaseURL else {
            report("Database", false, "Could not resolve database path")
            return 1
        }
        let database: NovPoolDatabase
        do {
            database = try NovPoolDatabase(path: databaseURL.path(percentEncoded: false))
            try await SchemaMigrator.migrate(database)
            let itemCount = try await KnowledgeRepository(database: database).count()
            report("Database writable (\(itemCount) existing items)", true, databaseURL.path(percentEncoded: false))
        } catch {
            report("Database writable", false, "\(error)")
            return 1
        }

        // 3. Staging
        let staging: StagingStore
        let imageData: Data
        do {
            staging = try StagingStore(root: NovPoolPaths.stagingRoot())
            guard let png = makeSampleImage(text: "NovPool Self-Test \(Date().formatted(date: .numeric, time: .standard))") else {
                report("Staging directory", false, "Could not generate test image")
                return 1
            }
            imageData = png
            let asset = try await staging.stage(data: png, preferredExtension: "png")
            let onDisk = FileManager.default.fileExists(atPath: asset.absoluteURL.path(percentEncoded: false))
            report("Staging write", onDisk && asset.sha256.count == 64, asset.relativePath)
        } catch {
            report("Staging write", false, "\(error)")
            return 1
        }

        // 4. Ingest
        let repository = KnowledgeRepository(database: database)
        // Title comes from provenance: use a fixed pageTitle so assertions and Search stay easy.
        let selfTestTitle = "NovPool Self-Test Item"
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
            report(
                "Drag ingest",
                result.record.title.isEmpty == false,
                "title=\(result.record.title) staging=\(result.record.localRelativePath ?? "none")"
            )
        } catch {
            report("Drag ingest", false, "\(error)")
            return 1
        }

        // 5. Enrichment (OCR needs system ANE; skip rather than fail when unavailable)
        let enrichment = await orchestrator.enrichAfterIngest(itemID: itemID)
        if let enrichment {
            report("Background enrichment", true, enrichment.summaryLine)
        } else {
            print("· Background enrichment: nothing produced this run (OCR needs ANE; text/web items depend on network and AI config)")
        }

        // 6. Search: full-text + recent
        do {
            let search = KnowledgeSearchService(repository: repository, staging: staging, embedder: nil)
            let hits = try await search.search(selfTestTitle)
            let found = hits.contains { $0.title == selfTestTitle }
            report(
                "Full-text search hit",
                found,
                found ? "returned \(hits.count)" : "returned \(hits.count): \(hits.map(\.title).joined(separator: " / "))"
            )

            let recent = try await search.recent(limit: 5)
            report("Recent items list", !recent.isEmpty, "\(recent.count) items")
        } catch {
            report("Full-text search hit", false, "\(error)")
        }

        // 7. Cloud sync path: connector hub + outbox (local mount works offline).
        //    Also verifies cascade: second job depends on the first and runs only after it succeeds.
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
                name: "Self-Test Archive A",
                connectorType: "local_mount",
                configJSON: try configJSON(root: firstRoot)
            ))
            try await connectorRepository.upsert(ConnectorRecord(
                id: "selftest-b",
                name: "Self-Test Archive B",
                connectorType: "local_mount",
                configJSON: try configJSON(root: secondRoot)
            ))

            let worker = OutboxSyncWorker(
                database: database,
                connectors: ConnectorHub(repository: connectorRepository),
                staging: staging
            )
            // Put A last on purpose to verify type-order places file connectors first and chains them.
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
                "Cloud sync + cascade",
                chained && firstRun.succeeded == 1 && secondRun.succeeded == 1
                    && succeeded == 2 && landed == 2,
                "cascade=\(chained) first=\(firstRun.succeeded) second=\(secondRun.succeeded) on disk=\(landed)"
            )
        } catch {
            report("Cloud sync + cascade", false, "\(error)")
        }

        print("")
        if failures == 0 {
            print("Self-test passed. Use menu “Search Knowledge…” and look for “NovPool Self-Test Item”.")
            return 0
        }
        print("Self-test failed \(failures) check(s); see output above and \(NovPoolLog.path)")
        return 1
    }

    /// Draw a bitmap with CoreText (no WindowServer required).
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
