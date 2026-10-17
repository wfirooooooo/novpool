import Foundation
import NovPoolCore
import NovPoolStorage

/// 溯源上下文提供者抽象。
public protocol BrowserContextProviding: Sendable {
    func captureContext() async -> SourceContext
}

extension BrowserContextExtractor: BrowserContextProviding {}

/// 一次入库的结果。
public struct IngestedItem: Sendable {
    public let payload: NormalizedPayload
    public let record: KnowledgeItemRecord
    public let stagedAsset: StagedAsset?
    public let routeDecision: RouteDecision
    /// 内容哈希命中已存在条目时为 `true`（不重复写入）。
    public let isDuplicate: Bool
}

/// 一次「落库 + 补齐」的完整结果。
public struct EnrichedIngest: Sendable {
    public let item: IngestedItem
    public let enrichment: ContentEnrichment?
    /// 补齐后的最新行（未启用补齐时等于入库时那一行）。
    public let record: KnowledgeItemRecord
}

/// 单条重新总结结果。
public enum ResummarizeItemResult: Sendable, Equatable {
    case updated(ContentEnrichment)
    case failed(id: UUID, title: String?, reason: String)
    case notFound(UUID)

    public var statusMessage: String {
        switch self {
        case .updated(let enrichment):
            return "已重新总结（\(enrichment.summaryLine)）"
        case .failed(_, let title, let reason):
            if let title { return "总结失败「\(title)」：\(reason)" }
            return "总结失败：\(reason)"
        case .notFound:
            return "总结失败：找不到条目"
        }
    }
}

/// 批量重新总结报告。
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
            return failures.first ?? "没有需要重新总结的条目"
        }
        var parts = ["已处理 \(attempted) 条，成功 \(succeeded) 条"]
        if !failures.isEmpty {
            let preview = failures.prefix(3).joined(separator: "；")
            parts.append("失败 \(failures.count) 条：\(preview)")
        }
        return parts.joined(separator: "。")
    }
}

/// 捕获 → 暂存 → 溯源 → 落库 的主流水线。
///
/// `ingest` 只做毫秒级工作并立即返回，保证拖拽松手后主线程与用户感知都不被阻塞；
/// OCR / 正文提取 / AI 增强由 `enrichAfterIngest` 在后台补齐并回填。
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

        // 拖入的是「链接」本身时，若浏览器溯源没给出当前页面地址（例如从非浏览器应用
        // 拖拽，或前台应用不可溯源），就用链接目标自身作为来源 URL，
        // 否则后续正文抓取会因为 sourceURL 为空而无法进行。
        // 拖拽浏览器标签时同理：标签自身的 URL 才是这条记录的来源主体，
        // 溯源到的活跃标签页地址只表示「从哪拖来的」。
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
            // 重复拖拽：丢掉本次多余的 Staging 副本，避免磁盘堆积。
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

    /// 先按内容指纹，再对网页链接兼容按 sourceURL 查找历史条目。
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
        // 本地文件（含图片 / 视频 / PDF）优先按原文件暂存，保留文件名与扩展名。
        if let first = content.fileURLs.first {
            return try await staging.stage(fileURL: first)
        }
        // 没有文件时（网页图片 / 内联媒体字节），把内存数据落盘。
        if let data = content.imageData {
            let typeIdentifier = content.imageTypeIdentifier ?? PasteboardTypeID.png
            return try await staging.stage(
                data: data,
                preferredExtension: ImageTypeMapping.fileExtension(for: typeIdentifier)
            )
        }
        return nil
    }

    // MARK: - 后台补齐

    /// 后台补齐一条已落库条目的正文 / OCR / AI 元数据。返回本次实际写入的字段。
    @discardableResult
    public func enrichAfterIngest(itemID: UUID) async -> ContentEnrichment? {
        guard let enricher, let record = try? await repository.fetch(id: itemID) else { return nil }
        let enrichment = await enricher.enrich(record: record)
        guard !enrichment.isEmpty else { return nil }
        do {
            try await persist(enrichment: enrichment, itemID: itemID)
        } catch {
            return nil
        }
        return enrichment
    }

    /// 对单条条目重新跑补齐（含 AI 总结），失败时带可读原因。
    public func resummarize(itemID: UUID) async -> ResummarizeItemResult {
        guard let enricher else {
            return .failed(id: itemID, title: nil, reason: "补齐流水线未启用")
        }
        guard let record = try? await repository.fetch(id: itemID) else {
            return .notFound(itemID)
        }
        let enrichment = await enricher.enrich(record: record)
        if enrichment.isEmpty {
            let reason = enrichment.aiFailureReason ?? "没有可写入的补齐结果"
            return .failed(id: itemID, title: record.title, reason: reason)
        }
        do {
            try await persist(enrichment: enrichment, itemID: itemID)
        } catch {
            return .failed(id: itemID, title: record.title, reason: "写入失败：\(error.localizedDescription)")
        }
        // 重新总结以 AI 字段为准；仅有 OCR/正文时也算部分成功，但仍提示 AI 原因。
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
            title: enrichment.title
        )
    }

    /// 批量重新总结：默认处理尚无 AI 摘要、但已有正文/OCR 的条目。
    public func resummarizeMissingSummaries(limit: Int = 20) async -> ResummarizeBatchReport {
        let records: [KnowledgeItemRecord]
        do {
            records = try await repository.recordsNeedingAISummary(limit: limit)
        } catch {
            return ResummarizeBatchReport(
                attempted: 0,
                succeeded: 0,
                failures: ["读取待总结条目失败：\(error.localizedDescription)"]
            )
        }
        guard !records.isEmpty else {
            return ResummarizeBatchReport(attempted: 0, succeeded: 0, failures: ["没有需要重新总结的条目"])
        }

        var succeeded = 0
        var failures: [String] = []
        for record in records {
            switch await resummarize(itemID: record.id) {
            case .updated:
                succeeded += 1
            case .failed(_, let title, let reason):
                failures.append("「\(title ?? record.title)」：\(reason)")
            case .notFound:
                failures.append("「\(record.title)」：条目已不存在")
            }
        }
        return ResummarizeBatchReport(
            attempted: records.count,
            succeeded: succeeded,
            failures: failures
        )
    }

    /// 同步等待补齐完成（单元测试与无界面自检使用；App 走 `enrichAfterIngest`）。
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

/// 标题拟定策略（纯函数，便于单测）。
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
            // 拖拽内容自带的标题（浏览器标签标题 / 链接文字）最贴切。
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
        return "未命名条目 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
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

/// 正文构造策略。
public enum BodyBuilder {
    /// Phase 1：纯文本直接入库；HTML 片段暂以纯文本兜底。
    /// Phase 2 接入 JavaScriptCore（Readability.js + Turndown.js）后，HTML 会先转成洁净 Markdown。
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
