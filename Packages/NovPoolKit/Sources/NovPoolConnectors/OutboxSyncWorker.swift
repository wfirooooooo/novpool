import Foundation
import NovPoolCore
import NovPoolStorage

/// An external event of a synchronization result (used by the App layer to update floating window prompts or refresh the list).
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

/// Transactional Outbox Worker.
///
/// Three things:
/// 1. Poll the tasks due in `sync_outbox_jobs` and call the corresponding connectors;
/// 2. On failure, retry with exponential backoff; terminate when the limit is exceeded and retain Errors;
/// 3. Cross-cloud cascade: Unlock downstream tasks (Notion record creation) after the prerequisite task (cloud upload) is successful.
///    And inject the cloud link returned from the pre-step into the downstream payload's `upstreamAssetURL`.
public actor OutboxSyncWorker {
    public struct Configuration: Sendable, Equatable {
        public var isEnabled: Bool
        public var batchSize: Int
        public var maxRetryCount: Int
        /// Backoff base: For the nth retry, wait base * 2^(n-1).
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

    /// Statistics of one round of processing.
    public struct RunResult: Sendable, Equatable {
        public var processed = 0
        public var succeeded = 0
        public var failed = 0
        /// The prerequisite task has not yet succeeded, continuing to wait.
        public var waiting = 0
        /// The number of downstream tasks unlocked in this round.
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
        let wasEnabled = self.configuration.isEnabled
        self.configuration = configuration
        if configuration.isEnabled, !wasEnabled {
            start()
        } else if !configuration.isEnabled, wasEnabled {
            stop()
        }
    }

    public func addObserver(_ observer: @escaping @Sendable (OutboxSyncEvent) -> Void) {
        observers.append(observer)
    }

    // MARK: - Join the team

    /// Write to the outbox according to the routing destination.
    ///
    /// Order is very important: **run the connectors that require the original file first (cloud drive / local mount), then run the structured connectors (Notion)**,
    /// This way, the latter can get the cloud link of the former — that is, 'first upload the large file to the cloud drive, then write the link into the knowledge base'.
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

    // MARK: - Polling

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

    /// Handle a round of due tasks. Tests and self-checks call it directly, without relying on the timer.
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
        // Number of preceding tasks still pending: Tasks in BLOCKED status will not be picked up by dueJobs.
        // Therefore, we count it separately here, so that the upper layer can display "There are still a few items in the queue."
        let counts = (try? await outbox.statusCounts()) ?? [:]
        result.waiting = counts[.blocked] ?? 0
        return result
    }

    // MARK: - Single-task processing

    private func process(job: OutboxJobRecord, now: Date, result: inout RunResult) async {
        guard let resolved = await connectors.resolve(connectorID: job.connectorID) else {
            await abandon(job: job, reason: "Connector not configured or disabled: \(job.connectorID)", now: now, result: &result)
            return
        }
        guard let record = try? await knowledge.fetch(id: job.itemID) else {
            await abandon(job: job, reason: "Item no longer exists: \(job.itemID.uuidString)", now: now, result: &result)
            return
        }

        var payload = record.toPayload()
        payload.localStagedURL = await stagedURL(for: record)

        if let parentID = job.dependsOnJobID {
            guard let parent = try? await outbox.fetch(id: parentID) else {
                await abandon(job: job, reason: "Upstream job missing: \(parentID.uuidString)", now: now, result: &result)
                return
            }
            switch parent.status {
            case .succeeded:
                guard let upstream = parent.remoteWebURL.flatMap(URL.init(string:)) else {
                    await abandon(job: job, reason: "Upstream job did not return a cloud link", now: now, result: &result)
                    return
                }
                payload.upstreamAssetURL = upstream
            case .failed:
                await abandon(
                    job: job,
                    reason: "Upstream job failed: \(parent.lastError ?? "unknown reason")",
                    now: now,
                    result: &result
                )
                return
            default:
                // The predecessor is still running or still backing off: remain blocked and wait for the next round.
                try? await outbox.markBlocked(id: job.id, dependsOnJobID: parentID, now: now)
                result.waiting += 1
                notify(OutboxSyncEvent(
                    jobID: job.id,
                    itemID: job.itemID,
                    connectorID: job.connectorID,
                    outcome: .waiting,
                    remoteWebURL: nil,
                    message: "Waiting for upstream job to finish"
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
            let message = Self.describe(error)
            // Authorization expired. Retrying is meaningless; just give up and prompt to go to settings to reauthorize.
            if Self.isAuthenticationFailure(error) {
                await abandon(
                    job: job,
                    reason: "\(message) (re-authorize in Settings)",
                    now: now,
                    result: &result
                )
                return
            }
            let retryCount = job.retryCount + 1
            if retryCount >= configuration.maxRetryCount {
                await abandon(job: job, reason: "Retried \(retryCount) time(s), giving up: \(message)", now: now, result: &result)
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
                    message: "\(message) (attempt\(retryCount)  ,\(Int(delay))s later)"
                ))
            }
        }
    }

    private func abandon(job: OutboxJobRecord, reason: String, now: Date, result: inout RunResult) async {
        try? await outbox.markAbandoned(id: job.id, error: reason, now: now)
        // Cascade failure: tasks that depend on it are also terminated to prevent the accumulation of zombie tasks.
        // The Errors information of the subtask should indicate 'precondition failure,' rather than copying the upstream error as is.
        _ = try? await outbox.failDependents(ofJobID: job.id, reason: "Upstream job failed: \(reason)", now: now)
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

    /// Exponential backoff: base * 2^(retryCount-1), with a maximum cap.
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
            return SecretRedactor.redact(novPoolError.errorDescription ?? "\(novPoolError)")
        }
        return SecretRedactor.redact(error.localizedDescription)
    }

    private static func isAuthenticationFailure(_ error: any Error) -> Bool {
        if case .authenticationRequired = error as? NovPoolError { return true }
        let text = describe(error).lowercased()
        return text.contains("Authorization expired")
            || text.contains("invalid_grant")
            || text.contains("Please re-authorize")
            || text.contains("Missing refresh token")
    }
}
