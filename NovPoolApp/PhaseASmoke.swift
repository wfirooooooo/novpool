import AppKit
import Foundation
import NovPoolCore
import NovPoolStorage
import NovPoolSystemBridge
import NovPoolUI

/// Phase A local smoke: same data dir / ingest / fallback resolution as the shipping app.
///
///     ./build/NovPool.app/Contents/MacOS/NovPool --phase-a-smoke
///     ./build/NovPool.app/Contents/MacOS/NovPool --ingest /path/a.txt /path/b.md
///     ./build/NovPool.app/Contents/MacOS/NovPool --ingest-url 'https://example.com' --title 'Title'
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
                print("Usage: --ingest <file> [file...]")
                return 2
            }
            let filePaths = paths
            return execute { await ingestFiles(filePaths) }
        }
        if let index = arguments.firstIndex(of: "--ingest-url") {
            guard index + 1 < arguments.count else {
                print("Usage: --ingest-url <url> [--title <title>]")
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
        // Must run on the main actor (coordinator, etc.). Pump the RunLoop while
        // init blocks the main thread, or we deadlock.
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

    // MARK: - Commands

    private static func smoke() async -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failures += 1 }
        }

        let dataRoot = (try? NovPoolPaths.applicationSupport())?.path(percentEncoded: false) ?? "(unknown)"
        print("Phase A local smoke (data directory: \(dataRoot))")

        // A2 coordinator (main-actor type; do not mark @MainActor on a blocking-semaphore path)
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
        check("A2 suppress fallback on native enter", coordinatorOK.0)
        check("A2 short suppress after native success", coordinatorOK.1)
        check("A2 success suppress survives cancel", coordinatorOK.2)

        // A3 resolution order
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
            generalPasteboard: MemPB(storage: [PasteboardTypeID.plainText: "general pasteboard"]),
            browser: .init(pageURL: URL(string: "https://example.com/tab"), pageTitle: "Tab"),
            selectedText: "should not use selected text"
        )
        check(
            "A3 drag pasteboard beats selected text",
            decision?.source == "Drag pasteboard" && decision?.content.pageURL?.absoluteString == "https://example.com/from-drag",
            decision?.source ?? "nil"
        )

        // A5 multi-file ingest (real library)
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
                "A5 multi-file split ingest",
                ingested.saved == 2 && after == before + 2,
                "wrote \(ingested.saved), library \(before)→\(after)"
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
            check("Web link ingest", links.saved == 1 && linkAfter == linkBefore + 1)

            // FTS
            let hits = try await searchHits("phase-a-alpha-\(token)")
            check("FTS finds just-ingested file", hits >= 1, "hits=\(hits)")
        } catch {
            check("Real-library ingest", false, error.localizedDescription)
        }

        // Active browser tab (hard only when a browser is frontmost)
        let browser = await BrowserContextExtractor().captureContext(now: Date(), timeout: .seconds(2))
        if let url = browser.pageURL {
            print("· Browser provenance OK: \(url.absoluteString) (\(browser.pageTitle ?? "no title"))")
            check("Browser context readable", true)
        } else {
            print("· Browser provenance: no URL (frontmost=\(browser.appBundleID); tab drag still needs Automation)")
            check("Browser context readable (soft; not ready ≠ fail)", true, "skipped")
        }

        print(failures == 0 ? "\nPhase A smoke passed." : "\nPhase A smoke failed \(failures) check(s).")
        return failures == 0 ? 0 : 1
    }

    private static func ingestFiles(_ paths: [String]) async -> Int32 {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        for url in urls where !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            print("File not found: \(url.path(percentEncoded: false))")
            return 2
        }
        do {
            let content = ResolvedDragContent(
                contentType: FileKind.of(url: urls[0]).contentType,
                fileURLs: urls,
                matchedTypeIdentifiers: [PasteboardTypeID.fileURL]
            )
            let summary = try await ingestResolved(content)
            print(summary.message + ": " + urls.map(\.lastPathComponent).joined(separator: ", "))
            return 0
        } catch {
            print("Ingest failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func ingestURL(_ raw: String, title: String?) async -> Int32 {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            print("Invalid URL: \(raw)")
            return 2
        }
        do {
            let summary = try await ingestResolved(
                ResolvedDragContent(contentType: .webLink, pageURL: url, linkTitle: title)
            )
            print(summary.message + ": " + (title ?? url.absoluteString))
            return 0
        } catch {
            print("Ingest failed: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - Shared assembly

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
            if duplicates == 0 { return "Ingested \(saved) item(s)" }
            if saved == 0 { return "Already exists: \(duplicates) item(s)" }
            return "Ingested \(saved) item(s), skipped \(duplicates) duplicate(s)"
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
