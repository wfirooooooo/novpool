import Foundation
import NovPoolCore
import NovPoolStorage

/// Provenance context provides abstraction.
public protocol BrowserContextProviding: Sendable {
    func captureContext() async -> SourceContext
}

extension BrowserContextExtractor: BrowserContextProviding {}

/// The result of a single storage entry.
public struct IngestedItem: Sendable {
    public let payload: NormalizedPayload
    public let record: KnowledgeItemRecord
    public let stagedAsset: StagedAsset?
    public let routeDecision: RouteDecision
    /// When a content hash hits an existing entry, it is `true` (no duplicate write).
    public let isDuplicate: Bool
}

/// A complete result of 'storage + completion.'
public struct EnrichedIngest: Sendable {
    public let item: IngestedItem
    public let enrichment: ContentEnrichment?
    /// The latest row after completion (when completion is not enabled, it is the same as the row at the time of entry into the database).
    public let record: KnowledgeItemRecord
}

/// Single Re-summarize result.
public enum ResummarizeItemResult: Sendable, Equatable {
    case updated(ContentEnrichment)
    case failed(id: UUID, title: String?, reason: String)
    case notFound(UUID)

    public var statusMessage: String {
        switch self {
        case .updated(let enrichment):
            return "Re-summarized (\(enrichment.summaryLine))"
        case .failed(_, let title, let reason):
            if let title { return "Summarize failed \"\(title)\": \(reason)" }
            return "Summarize failed: \(reason)"
        case .notFound:
            return "Summarize failed: item not found"
        }
    }
}

/// Batch Re-summarize report.
public struct ResummarizeBatchReport: Sendable, Equatable {
    public var attempted: Int
    public var succeeded: Int
    public var failures: [String]

    public init(attempted: Int, succeeded: Int, failures: [String]) {
        self.attempted = attempted
        self.succeeded = succeeded
        self.failures = failures
    }

    public var statusMessage: String {
        if attempted == 0 {
            return failures.first ?? "No items need re-summarizing"
        }
        var parts = ["Processed \(attempted), succeeded \(succeeded)"]
        if !failures.isEmpty {
            let preview = failures.prefix(3).joined(separator: "; ")
            parts.append("failed \(failures.count): \(preview)")
        }
        return parts.joined(separator: ". ")
    }
}

/// The main pipeline of capture → staging → tracing → storage.
///
/// `ingest` only performs millisecond-level tasks and returns immediately, ensuring that after dragging and releasing, neither the main thread nor the user's perception is blocked.
/// OCR / Body extraction / AI enhancement is supplemented and backfilled in the background by `enrichAfterIngest`.
public actor IngestionOrchestrator {
    private let repository: KnowledgeRepository
    private let staging: StagingStore
    private let browserContext: BrowserContextProviding
    private let enricher: (any ContentEnriching)?
    public var routeEvaluator: RouteEvaluator

    public init(
        database: NovPoolDatabase,
        staging: StagingStore,
        browserContext: BrowserContextProviding,
        routeEvaluator: RouteEvaluator = RouteEvaluator(),
        enricher: (any ContentEnriching)? = nil
    ) {
        self.repository = KnowledgeRepository(database: database)
        self.staging = staging
        self.browserContext = browserContext
        self.routeEvaluator = routeEvaluator
        self.enricher = enricher
    }

    public func update(routeEvaluator: RouteEvaluator) {
        self.routeEvaluator = routeEvaluator
    }

    public func ingest(
        _ content: ResolvedDragContent,
        forcedZone: DropZone? = nil
    ) async throws -> IngestedItem {
        let sourceContext = await browserContext.captureContext()
        return try await ingest(content, sourceContext: sourceContext, forcedZone: forcedZone)
    }

    public func ingest(
        _ content: ResolvedDragContent,
        sourceContext: SourceContext,
        forcedZone: DropZone? = nil
    ) async throws -> IngestedItem {
        let staged = try await stage(content)

        // When what is dragged in is the "Link" itself, if the browser's referrer does not provide the current page address (for example, from a non-browser application
        // Drag-and-drop, or non-traceable frontend applications), then use the Link target itself as the source URL,
        // Otherwise, subsequent Body fetching will fail because sourceURL is empty.
        // The same applies when dragging a browser tab: the URL of the tab itself is the main source of this record.
        // The traced active tab address only indicates 'where it was dragged from'.
        let resolvedPageURL: URL? = content.contentType == .webLink
            ? (content.pageURL ?? sourceContext.pageURL)
            : sourceContext.pageURL
        let resolvedContext = SourceContext(
            appBundleID: sourceContext.appBundleID,
            pageURL: resolvedPageURL,
            pageTitle: sourceContext.pageTitle,
            capturedAt: sourceContext.capturedAt
        )

        let fingerprint = ContentFingerprint.digest(
            for: content,
            stagedHash: staged?.sha256,
            resolvedPageURL: resolvedPageURL
        )
        if let existing = try await findDuplicate(
            fingerprint: fingerprint,
            contentType: content.contentType,
            pageURL: resolvedPageURL
        ) {
            // Repeated dragging: discard this excess Staging copy to avoid disk accumulation.
            if let staged, staged.relativePath != existing.localRelativePath {
                try? await staging.remove(relativePath: staged.relativePath)
            }
            return IngestedItem(
                payload: existing.toPayload(),
                record: existing,
                stagedAsset: nil,
                routeDecision: routeEvaluator.evaluate(payload: existing.toPayload(), forcedZone: forcedZone),
                isDuplicate: true
            )
        }

        let title = TitleBuilder.suggest(for: content, sourceContext: sourceContext)
        let payload = NormalizedPayload(
            contentType: content.contentType,
            title: title,
            markdownBody: BodyBuilder.body(for: content),
            ocrText: nil,
            aiSummary: nil,
            aiCategory: nil,
            aiTags: [],
            localStagedURL: staged?.absoluteURL,
            fileHashSHA256: fingerprint,
            sourceContext: resolvedContext
        )

        let record = KnowledgeItemRecord(payload: payload, localRelativePath: staged?.relativePath)
        try await repository.insert(record)

        return IngestedItem(
            payload: payload,
            record: record,
            stagedAsset: staged,
            routeDecision: routeEvaluator.evaluate(payload: payload, forcedZone: forcedZone),
            isDuplicate: false
        )
    }

    /// First search by content fingerprint, then for WebLink compatibility, search historical entries by sourceURL.
    private func findDuplicate(
        fingerprint: String?,
        contentType: ContentType,
        pageURL: URL?
    ) async throws -> KnowledgeItemRecord? {
        if let fingerprint, let existing = try await repository.fetchByHash(fingerprint) {
            return existing
        }
        guard contentType == .webLink, let pageURL else { return nil }
        let candidates = [
            pageURL.absoluteString,
            ContentFingerprint.canonicalURLString(pageURL),
        ]
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if let existing = try await repository.fetchBySourceURL(candidate) {
                return existing
            }
        }
        return nil
    }

    private func stage(_ content: ResolvedDragContent) async throws -> StagedAsset? {
        // Local files (including images, videos, and PDFs) should preferably be temporarily stored as the original files, retaining the file name and extension.
        if let first = content.fileURLs.first {
            return try await staging.stage(fileURL: first)
        }
        // When there is no File (WebImage / inline media bytes), write the in-memory data to disk.
        if let data = content.imageData {
            let typeIdentifier = content.imageTypeIdentifier ?? PasteboardTypeID.png
            return try await staging.stage(
                data: data,
                preferredExtension: ImageTypeMapping.fileExtension(for: typeIdentifier)
            )
        }
        return nil
    }

    // MARK: - Backend completion

    /// Supplement the Body / OCR / AI metadata of an entry that has already been stored in the backend. Return the fields actually written this time.
    @discardableResult
    public func enrichAfterIngest(itemID: UUID) async -> ContentEnrichment? {
        guard let enricher, let record = try? await repository.fetch(id: itemID) else { return nil }
        let enrichment = await enricher.enrich(record: record)
        // A failure reason alone is worth storing so the detail pane can show why there is no summary.
        guard !enrichment.isEmpty || enrichment.aiFailureReason != nil else { return nil }
        do {
            try await persist(enrichment: enrichment, itemID: itemID)
        } catch {
            return nil
        }
        return enrichment
    }

    /// Re-run completion for individual entries (including AI summary), with a readable reason if it fails.
    public func resummarize(itemID: UUID) async -> ResummarizeItemResult {
        guard let enricher else {
            return .failed(id: itemID, title: nil, reason: "Enrichment pipeline is not enabled")
        }
        guard let record = try? await repository.fetch(id: itemID) else {
            return .notFound(itemID)
        }
        let enrichment = await enricher.enrich(record: record)
        let hadSummary = !(record.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        // Sticky failure text belongs on items that still have no summary. If a previous summary
        // remains, keep the row and surface the attempt failure in the status / Retry chrome only.
        if let reason = enrichment.aiFailureReason, !enrichment.hasAIFields, hadSummary {
            return .failed(id: itemID, title: record.title, reason: reason)
        }
        let shouldPersist = !enrichment.isEmpty || enrichment.aiFailureReason != nil
        guard shouldPersist else {
            return .failed(id: itemID, title: record.title, reason: "No enrichment result to write")
        }
        do {
            try await persist(enrichment: enrichment, itemID: itemID)
        } catch {
            return .failed(id: itemID, title: record.title, reason: "Write failed: \(error.localizedDescription)")
        }
        if enrichment.hasAIFields {
            return .updated(enrichment)
        }
        if let reason = enrichment.aiFailureReason {
            return .failed(id: itemID, title: record.title, reason: reason)
        }
        return .updated(enrichment)
    }

    private func persist(enrichment: ContentEnrichment, itemID: UUID) async throws {
        try await repository.updateEnrichment(
            id: itemID,
            markdownBody: enrichment.markdownBody,
            ocrText: enrichment.ocrText,
            aiSummary: enrichment.aiSummary,
            aiCategory: enrichment.aiCategory,
            aiTags: enrichment.aiTags,
            embedding: enrichment.embedding,
            title: enrichment.title,
            aiFailureReason: enrichment.aiFailureReason,
            writeAIFailureReason: enrichment.aiFailureReason != nil || enrichment.hasAIFields
        )
    }

    /// Batch Re-summarize: By default, it processes entries that do not yet have an AI summary, but already have Body/OCR.
    public func resummarizeMissingSummaries(limit: Int = 20) async -> ResummarizeBatchReport {
        let records: [KnowledgeItemRecord]
        do {
            records = try await repository.recordsNeedingAISummary(limit: limit)
        } catch {
            return ResummarizeBatchReport(
                attempted: 0,
                succeeded: 0,
                failures: ["Failed to load items to summarize: \(error.localizedDescription)"]
            )
        }
        guard !records.isEmpty else {
            return ResummarizeBatchReport(attempted: 0, succeeded: 0, failures: ["No items need re-summarizing"])
        }

        var succeeded = 0
        var failures: [String] = []
        for record in records {
            switch await resummarize(itemID: record.id) {
            case .updated:
                succeeded += 1
            case .failed(_, let title, let reason):
                failures.append("\"\(title ?? record.title)\": \(reason)")
            case .notFound:
                failures.append("\"\(record.title)\": item no longer exists")
            }
        }
        return ResummarizeBatchReport(
            attempted: records.count,
            succeeded: succeeded,
            failures: failures
        )
    }

    /// Wait synchronously for completion of filling in (used for unit tests and headless self-check; App uses `enrichAfterIngest`).
    public func ingestAndEnrich(
        _ content: ResolvedDragContent,
        sourceContext: SourceContext? = nil,
        forcedZone: DropZone? = nil
    ) async throws -> EnrichedIngest {
        let item: IngestedItem
        if let sourceContext {
            item = try await ingest(content, sourceContext: sourceContext, forcedZone: forcedZone)
        } else {
            item = try await ingest(content, forcedZone: forcedZone)
        }

        let enrichment = await enrichAfterIngest(itemID: item.record.id)
        let record = (try? await repository.fetch(id: item.record.id)) ?? item.record
        return EnrichedIngest(item: item, enrichment: enrichment, record: record)
    }
}

/// Title Drafting Strategy (Pure Function, Easy for Unit Testing).
public enum TitleBuilder {
    public static let maxTitleLength = 80

    public static func suggest(for content: ResolvedDragContent, sourceContext: SourceContext) -> String {
        switch content.contentType {
        case .genericFile, .documentPDF:
            if let name = content.fileURLs.first?.deletingPathExtension().lastPathComponent, !name.isEmpty {
                return name
            }
        case .video:
            if let name = content.fileURLs.first?.deletingPathExtension().lastPathComponent, !name.isEmpty {
                return name
            }
            if let pageTitle = sourceContext.pageTitle, !pageTitle.isEmpty {
                return clamp(pageTitle)
            }
        case .webLink, .image:
            // The title that comes with the dragged content (Browser tab title / Link text) is the most appropriate.
            if let linkTitle = content.linkTitle, linkTitle.count >= 2 {
                return clamp(linkTitle)
            }
            if let pageTitle = sourceContext.pageTitle, !pageTitle.isEmpty {
                return clamp(pageTitle)
            }
            if let host = content.pageURL?.host() {
                return host
            }
        case .richHTML, .plainText:
            if let firstLine = firstMeaningfulLine(of: content.text ?? content.html) {
                return clamp(firstLine)
            }
            if let pageTitle = sourceContext.pageTitle, !pageTitle.isEmpty {
                return clamp(pageTitle)
            }
        }
        return "Untitled item \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
    }

    static func firstMeaningfulLine(of text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func clamp(_ value: String) -> String {
        guard value.count > maxTitleLength else { return value }
        return String(value.prefix(maxTitleLength)) + "…"
    }
}

/// Body construction strategy.
public enum BodyBuilder {
    /// Phase 1: Plain text is directly stored in the database; HTML fragments are temporarily handled as plain text.
    /// After Phase 2 integrates JavaScriptCore (Readability.js + Turndown.js), HTML will first be converted into clean Markdown.
    public static func body(for content: ResolvedDragContent) -> String? {
        switch content.contentType {
        case .plainText, .richHTML:
            return content.text ?? content.html
        case .webLink:
            return nil
        case .image, .genericFile, .documentPDF:
            return nil
        case .video:
            return nil
        }
    }
}
