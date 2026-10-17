import Foundation
import NovPoolCore
import NovPoolStorage

/// 一次同步结果的对外事件（App 层用来更新悬浮窗提示或刷新列表）。
public struct OutboxSyncEvent: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        case succeeded
        case failed
        case abandoned
        case waiting
    }

    public var jobID: UUID
    public var itemID: UUID
    public var connectorID: String
    public var outcome: Outcome
    public var remoteWebURL: URL?
    public var message: String?
}

/// 事务性发件箱工作器。
///
/// 三件事：
/// 1. 轮询 `sync_outbox_jobs` 里到期的任务并调用对应连接器；
/// 2. 失败按指数退避重试，超过上限终止并保留错误；
/// 3. 跨云级联：前置任务（网盘上传）成功后解锁下游任务（Notion 建档），
///    并把前置返回的云端链接注入下游载荷的 `upstreamAssetURL`。
public actor OutboxSyncWorker {
    public struct Configuration: Sendable, Equatable {
        public var isEnabled: Bool
        public var batchSize: Int
        public var maxRetryCount: Int
        /// 退避基数：第 n 次重试等待 base * 2^(n-1)。
        public var baseBackoff: TimeInterval
        public var backoffCap: TimeInterval
        public var pollInterval: Duration

        public init(
            isEnabled: Bool = true,
            batchSize: Int = 10,
            maxRetryCount: Int = 5,
            baseBackoff: TimeInterval = 2,
            backoffCap: TimeInterval = 300,
            pollInterval: Duration = .seconds(5)
        ) {
            self.isEnabled = isEnabled
            self.batchSize = batchSize
            self.maxRetryCount = maxRetryCount
            self.baseBackoff = baseBackoff
            self.backoffCap = backoffCap
            self.pollInterval = pollInterval
        }
    }

    /// 一轮处理的统计。
    public struct RunResult: Sendable, Equatable {
        public var processed = 0
        public var succeeded = 0
        public var failed = 0
        /// 前置任务尚未成功、继续等待的数量。
        public var waiting = 0
        /// 本轮解锁的下游任务数量。
        public var released = 0

        public init() {}
    }

    private let outbox: OutboxRepository
    private let knowledge: KnowledgeRepository
    private let connectors: any ConnectorProviding
    private let staging: StagingStore?
    private let clock: @Sendable () -> Date
    private var configuration: Configuration
    private var loopTask: Task<Void, Never>?
    private var observers: [@Sendable (OutboxSyncEvent) -> Void] = []

    public init(
        database: NovPoolDatabase,
        connectors: any ConnectorProviding,
        staging: StagingStore? = nil,
        configuration: Configuration = Configuration(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.outbox = OutboxRepository(database: database)
        self.knowledge = KnowledgeRepository(database: database)
        self.connectors = connectors
        self.staging = staging
        self.configuration = configuration
        self.clock = clock
    }

    public func update(configuration: Configuration) {
        self.configuration = configuration
    }

    public func addObserver(_ observer: @escaping @Sendable (OutboxSyncEvent) -> Void) {
        observers.append(observer)
    }

    // MARK: - 入队

    /// 按路由目标写入发件箱。
    ///
    /// 顺序很关键：**先跑需要原始文件的连接器（网盘 / 本地挂载），后跑结构化连接器（Notion）**，
    /// 这样后者能拿到前者的云端链接——即「大文件先传网盘，再把链接写进知识库」。
    @discardableResult
    public func enqueue(itemID: UUID, connectorIDs: [String]) async throws -> [UUID] {
        guard !connectorIDs.isEmpty else { return [] }

        var ordered: [String] = []
        for id in connectorIDs where !ordered.contains(id) { ordered.append(id) }

        var fileCapable: [String] = []
        var structured: [String] = []
        for id in ordered {
            let type = await connectors.resolve(connectorID: id)?.type
            if let type, ConnectorHub.fileFirstTypes.contains(type) {
                fileCapable.append(id)
            } else {
                structured.append(id)
            }
        }

        var jobIDs: [UUID] = []
        var previous: UUID?
        for connectorID in fileCapable + structured {
            let jobID = try await outbox.enqueue(
                itemID: itemID,
                connectorID: connectorID,
                dependsOnJobID: previous,
                now: clock()
            )
            jobIDs.append(jobID)
            previous = jobID
        }
        return jobIDs
    }

    // MARK: - 轮询

    public func start() {
        guard configuration.isEnabled, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = await self.runOnce()
                let interval = await self.configuration.pollInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// 处理一轮到期任务。测试与自检直接调用它，不依赖计时器。
    @discardableResult
    public func runOnce() async -> RunResult {
        var result = RunResult()
        guard configuration.isEnabled else { return result }

        let now = clock()
        let jobs = (try? await outbox.dueJobs(now: now, limit: configuration.batchSize)) ?? []
        for job in jobs {
            result.processed += 1
            await process(job: job, now: now, result: &result)
        }
        // 仍在等待前置的任务数：BLOCKED 状态的任务不会被 dueJobs 取出，
        // 因此这里单独统计，让上层能显示「还有几件在排队」。
        let counts = (try? await outbox.statusCounts()) ?? [:]
        result.waiting = counts[.blocked] ?? 0
        return result
    }

    // MARK: - 单任务处理

    private func process(job: OutboxJobRecord, now: Date, result: inout RunResult) async {
        guard let resolved = await connectors.resolve(connectorID: job.connectorID) else {
            await abandon(job: job, reason: "连接器未配置或已禁用：\(job.connectorID)", now: now, result: &result)
            return
        }
        guard let record = try? await knowledge.fetch(id: job.itemID) else {
            await abandon(job: job, reason: "条目已不存在：\(job.itemID.uuidString)", now: now, result: &result)
            return
        }

        var payload = record.toPayload()
        payload.localStagedURL = await stagedURL(for: record)

        if let parentID = job.dependsOnJobID {
            guard let parent = try? await outbox.fetch(id: parentID) else {
                await abandon(job: job, reason: "前置任务丢失：\(parentID.uuidString)", now: now, result: &result)
                return
            }
            switch parent.status {
            case .succeeded:
                guard let upstream = parent.remoteWebURL.flatMap(URL.init(string:)) else {
                    await abandon(job: job, reason: "前置任务未返回云端链接", now: now, result: &result)
                    return
                }
                payload.upstreamAssetURL = upstream
            case .failed:
                await abandon(
                    job: job,
                    reason: "前置任务失败：\(parent.lastError ?? "未知原因")",
                    now: now,
                    result: &result
                )
                return
            default:
                // 前置还在跑或还在退避：保持阻塞，等下一轮。
                try? await outbox.markBlocked(id: job.id, dependsOnJobID: parentID, now: now)
                result.waiting += 1
                notify(OutboxSyncEvent(
                    jobID: job.id,
                    itemID: job.itemID,
                    connectorID: job.connectorID,
                    outcome: .waiting,
                    remoteWebURL: nil,
                    message: "等待前置任务完成"
                ))
                return
            }
        }

        try? await outbox.markRunning(id: job.id, now: now)
        do {
            let receipt = try await resolved.connector.push(
                payload: payload,
                configJSON: resolved.record.configData
            )
            try? await outbox.markSucceeded(id: job.id, receipt: receipt, now: now)
            result.succeeded += 1
            let released = (try? await outbox.releaseDependents(ofJobID: job.id, now: now)) ?? []
            result.released += released.count
            notify(OutboxSyncEvent(
                jobID: job.id,
                itemID: job.itemID,
                connectorID: job.connectorID,
                outcome: .succeeded,
                remoteWebURL: receipt.remoteWebURL,
                message: nil
            ))
        } catch {
            let retryCount = job.retryCount + 1
            let message = Self.describe(error)
            if retryCount >= configuration.maxRetryCount {
                await abandon(job: job, reason: "重试 \(retryCount) 次后放弃：\(message)", now: now, result: &result)
            } else {
                let delay = backoffDelay(retryCount: retryCount)
                try? await outbox.markFailed(
                    id: job.id,
                    error: message,
                    retryCount: retryCount,
                    nextRetryAt: now.addingTimeInterval(delay),
                    now: now
                )
                result.failed += 1
                notify(OutboxSyncEvent(
                    jobID: job.id,
                    itemID: job.itemID,
                    connectorID: job.connectorID,
                    outcome: .failed,
                    remoteWebURL: nil,
                    message: "\(message)（第 \(retryCount) 次，\(Int(delay))s 后重试）"
                ))
            }
        }
    }

    private func abandon(job: OutboxJobRecord, reason: String, now: Date, result: inout RunResult) async {
        try? await outbox.markAbandoned(id: job.id, error: reason, now: now)
        // 级联失败：依赖它的任务也一并终止，避免僵尸任务堆积。
        // 子任务的错误信息要说明「是前置失败」，而不是原样照抄上游的报错。
        _ = try? await outbox.failDependents(ofJobID: job.id, reason: "前置任务失败：\(reason)", now: now)
        result.failed += 1
        notify(OutboxSyncEvent(
            jobID: job.id,
            itemID: job.itemID,
            connectorID: job.connectorID,
            outcome: .abandoned,
            remoteWebURL: nil,
            message: reason
        ))
    }

    /// 指数退避：base * 2^(retryCount-1)，上限 cap。
    func backoffDelay(retryCount: Int) -> TimeInterval {
        let exponent = max(retryCount - 1, 0)
        let raw = configuration.baseBackoff * pow(2, Double(exponent))
        return min(raw, configuration.backoffCap)
    }

    private func stagedURL(for record: KnowledgeItemRecord) async -> URL? {
        guard let staging, let relativePath = record.localRelativePath else { return nil }
        let url = await staging.absoluteURL(forRelativePath: relativePath)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    private func notify(_ event: OutboxSyncEvent) {
        for observer in observers {
            observer(event)
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let novPoolError = error as? NovPoolError {
            return novPoolError.errorDescription ?? "\(novPoolError)"
        }
        return error.localizedDescription
    }
}
