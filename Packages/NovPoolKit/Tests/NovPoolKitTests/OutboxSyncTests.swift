import Foundation
@testable import NovPoolConnectors
import NovPoolCore
import NovPoolStorage
import Testing

/// A connector stand-in for recording pushed content.
final class RecordingConnector: DestinationConnector, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let connectorType: String
    private let lock = NSLock()
    private var recorded: [NormalizedPayload] = []
    private var outcome: Result<RemoteReceipt, any Error>

    init(connectorType: String, remoteURL: String = "https://cloud.example.com/f/1") {
        self.connectorType = connectorType
        self.outcome = .success(RemoteReceipt(
            connectorID: connectorType,
            remoteItemID: "remote-1",
            remoteWebURL: URL(string: remoteURL)!
        ))
    }

    var payloads: [NormalizedPayload] {
        withLock { recorded }
    }

    func fail(with message: String) {
        withLock { outcome = .failure(Failure(message: message)) }
    }

    func succeed(remoteURL: String) {
        withLock {
            outcome = .success(RemoteReceipt(
                connectorID: connectorType,
                remoteItemID: "remote-\(UUID().uuidString.prefix(4))",
                remoteWebURL: URL(string: remoteURL)!
            ))
        }
    }

    func validateAuthentication(configJSON: Data) async throws -> Bool { true }

    func push(payload: NormalizedPayload, configJSON: Data) async throws -> RemoteReceipt {
        // NSLock is marked as unavailable in async contexts, so a synchronous helper method is used for locking.
        let result = withLock { () -> Result<RemoteReceipt, any Error> in
            recorded.append(payload)
            return outcome
        }
        return try result.get()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Returns a proxy for the preset connector.
struct StubConnectorProvider: ConnectorProviding {
    var connectors: [String: ResolvedConnector]

    func resolve(connectorID: String) async -> ResolvedConnector? {
        connectors[connectorID]
    }
}

/// A clock that can be advanced.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

@Suite("Outbox Synchronization: Cascading, Backoff, and Retry")
struct OutboxSyncTests {
    private struct Harness {
        let database: NovPoolDatabase
        let repository: KnowledgeRepository
        let outbox: OutboxRepository
        let connectors: ConnectorRepository
        let staging: StagingStore
        let directory: URL
    }

    private func makeHarness() async throws -> Harness {
        let directory = try TestSupport.makeTemporaryDirectory("outbox")
        let database = try NovPoolDatabase(path: directory.appending(path: "db.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        let staging = try StagingStore(root: directory.appending(path: "Staging", directoryHint: .isDirectory))
        let connectors = ConnectorRepository(database: database)
        // The outbox foreign key requires the connector to be registered first (consistent with the white paper schema), so here we register all those used for testing.
        for entry in [
            (id: "gdrive", type: "gdrive_api"),
            (id: "onedrive", type: "onedrive_api"),
            (id: "notion", type: "notion"),
            (id: "obsidian", type: "local_mount"),
            (id: "ghost", type: "notion"),
        ] {
            try await connectors.upsert(ConnectorRecord(id: entry.id, name: entry.id, connectorType: entry.type))
        }
        return Harness(
            database: database,
            repository: KnowledgeRepository(database: database),
            outbox: OutboxRepository(database: database),
            connectors: connectors,
            staging: staging,
            directory: directory
        )
    }

    private func insertItem(
        _ harness: Harness,
        title: String = "Quarterly report",
        relativePath: String? = nil
    ) async throws -> KnowledgeItemRecord {
        let payload = NormalizedPayload(
            contentType: .documentPDF,
            title: title,
            markdownBody: "# Report Body",
            aiCategory: "Technology",
            aiTags: ["Report"],
            sourceContext: SourceContext(appBundleID: "com.apple.finder", pageURL: URL(string: "https://example.com/r"))
        )
        var record = KnowledgeItemRecord(payload: payload, localRelativePath: relativePath)
        record.localRelativePath = relativePath
        try await harness.repository.insert(record)
        return record
    }

    private func resolved(
        id: String,
        type: String,
        connector: any DestinationConnector
    ) -> ResolvedConnector {
        ResolvedConnector(
            id: id,
            type: type,
            record: ConnectorRecord(id: id, name: id, connectorType: type, configJSON: "{}"),
            connector: connector
        )
    }

    /// Get tasks by connector ID — `jobs(forItem:)` is sorted by updateTime, the position will change with retries,
    /// Assertions are only stable when indexed by ID.
    private func jobsByConnector(_ harness: Harness, itemID: UUID) async throws -> [String: OutboxJobRecord] {
        let records = try await harness.outbox.jobs(forItem: itemID)
        return Dictionary(records.map { ($0.connectorID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Enqueue Order and Cascading Dependencies

    @Test("Joining order: The connector for the original file needs to run first, as the structured connector depends on it.")
    func enqueueOrdersFileFirst() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let drive = RecordingConnector(connectorType: "gdrive_api")
        let notion = RecordingConnector(connectorType: "notion")
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: StubConnectorProvider(connectors: [
                "notion": resolved(id: "notion", type: "notion", connector: notion),
                "gdrive": resolved(id: "gdrive", type: "gdrive_api", connector: drive),
            ]),
            staging: harness.staging
        )

        // Even if the user selects Notion first, they will be ranked after cloud drives.
        let jobs = try await worker.enqueue(itemID: item.id, connectorIDs: ["notion", "gdrive"])
        #expect(jobs.count == 2)

        let records = try await harness.outbox.jobs(forItem: item.id)
        let driveJob = try #require(records.first { $0.connectorID == "gdrive" })
        let notionJob = try #require(records.first { $0.connectorID == "notion" })
        #expect(driveJob.dependsOnJobID == nil)
        #expect(notionJob.dependsOnJobID == driveJob.id)
        #expect(driveJob.status == .pending)
        #expect(notionJob.status == .blocked)
        #expect(jobs.count == 2)
    }

    @Test("Cascade: The cloud drive first uploads the File, and the Link is automatically injected into the downstream Notion payload")
    func cascadeInjectsUpstreamURL() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let drive = RecordingConnector(connectorType: "gdrive_api", remoteURL: "https://drive.google.com/file/d/ABC/view")
        let notion = RecordingConnector(connectorType: "notion")
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: StubConnectorProvider(connectors: [
                "gdrive": resolved(id: "gdrive", type: "gdrive_api", connector: drive),
                "notion": resolved(id: "notion", type: "notion", connector: notion),
            ]),
            staging: harness.staging
        )

        try await worker.enqueue(itemID: item.id, connectorIDs: ["gdrive", "notion"])

        // Round 1: Only run cloud drives, keep Notion on standby
        let first = await worker.runOnce()
        #expect(first.succeeded == 1)
        #expect(first.released == 1)
        #expect(notion.payloads.isEmpty)

        // Second round: Notion gets the upstream link
        let second = await worker.runOnce()
        #expect(second.succeeded == 1)
        let downstream = try #require(notion.payloads.first)
        #expect(downstream.upstreamAssetURL?.absoluteString == "https://drive.google.com/file/d/ABC/view")

        let byConnector = try await jobsByConnector(harness, itemID: item.id)
        #expect(byConnector.values.allSatisfy { $0.status == .succeeded })
        #expect(byConnector["gdrive"]?.remoteWebURL == "https://drive.google.com/file/d/ABC/view")
        #expect(byConnector["notion"]?.remoteWebURL != nil)
    }

    @Test("When the upstream task has not finished running, the downstream remains blocked and will not be pushed forward prematurely.")
    func downstreamWaitsForUpstream() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let drive = RecordingConnector(connectorType: "gdrive_api")
        drive.fail(with: "Network unreachable")
        let notion = RecordingConnector(connectorType: "notion")
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: StubConnectorProvider(connectors: [
                "gdrive": resolved(id: "gdrive", type: "gdrive_api", connector: drive),
                "notion": resolved(id: "notion", type: "notion", connector: notion),
            ]),
            staging: harness.staging
        )
        try await worker.enqueue(itemID: item.id, connectorIDs: ["gdrive", "notion"])

        let result = await worker.runOnce()
        #expect(result.failed == 1)
        #expect(result.waiting == 1)
        #expect(notion.payloads.isEmpty)

        let byConnector = try await jobsByConnector(harness, itemID: item.id)
        #expect(byConnector["notion"]?.status == .blocked)
        #expect(byConnector["gdrive"]?.status == .pending)
    }

    @Test("When the preceding task ultimately fails, the downstream task is terminated with a clear reason")
    func downstreamAbandonedWhenUpstreamFails() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let drive = RecordingConnector(connectorType: "gdrive_api")
        let notion = RecordingConnector(connectorType: "notion")
        let provider = StubConnectorProvider(connectors: [
            "gdrive": resolved(id: "gdrive", type: "gdrive_api", connector: drive),
            "notion": resolved(id: "notion", type: "notion", connector: notion),
        ])
        let clock = MutableClock()
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: provider,
            staging: harness.staging,
            configuration: .init(maxRetryCount: 2, baseBackoff: 10),
            clock: { clock.now }
        )
        try await worker.enqueue(itemID: item.id, connectorIDs: ["gdrive", "notion"])
        drive.fail(with: "Quota exceeded")

        // Complete the backoff time of the prerequisite task until all retries are exhausted
        _ = await worker.runOnce()
        clock.advance(by: 60)
        _ = await worker.runOnce()
        clock.advance(by: 600)
        let final = await worker.runOnce()
        // Round three: Both tasks have been terminated, and there are no tasks to process; there should also be no zombie tasks left in the queue.
        #expect(final.processed == 0)
        #expect(final.waiting == 0)

        let byConnector = try await jobsByConnector(harness, itemID: item.id)
        #expect(byConnector["gdrive"]?.status == .failed)
        #expect(byConnector["gdrive"]?.lastError?.contains("giving up") == true)
        #expect(byConnector["notion"]?.status == .failed)
        #expect(byConnector["notion"]?.lastError?.contains("Upstream job failed") == true)
        #expect(notion.payloads.isEmpty)
    }

    // MARK: - Retreat

    @Test("Failures will retry with exponential backoff, and will not be fetched again before the retry time.")
    func exponentialBackoff() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let connector = RecordingConnector(connectorType: "notion")
        connector.fail(with: "Server 500")
        let clock = MutableClock()
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: StubConnectorProvider(connectors: [
                "notion": resolved(id: "notion", type: "notion", connector: connector),
            ]),
            staging: harness.staging,
            configuration: .init(maxRetryCount: 5, baseBackoff: 2, backoffCap: 100),
            clock: { clock.now }
        )
        try await worker.enqueue(itemID: item.id, connectorIDs: ["notion"])

        let first = await worker.runOnce()
        #expect(first.processed == 1)
        #expect(first.failed == 1)

        // During the waiting period: Should not be removed
        let immediate = await worker.runOnce()
        #expect(immediate.processed == 0)

        clock.advance(by: 3)
        let afterBackoff = await worker.runOnce()
        #expect(afterBackoff.processed == 1)

        let job = try #require(try await harness.outbox.jobs(forItem: item.id).first)
        #expect(job.retryCount == 2)
        #expect(job.lastError?.contains("Server 500") == true)
    }

    @Test("The backoff duration is calculated as base * 2^(n-1) when long pressed and is subject to an upper limit")
    func backoffDelays() async throws {
        let harness = try await makeHarness()
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: StubConnectorProvider(connectors: [:]),
            configuration: .init(maxRetryCount: 10, baseBackoff: 3, backoffCap: 40)
        )
        #expect(await worker.backoffDelay(retryCount: 1) == 3)
        #expect(await worker.backoffDelay(retryCount: 2) == 6)
        #expect(await worker.backoffDelay(retryCount: 3) == 12)
        #expect(await worker.backoffDelay(retryCount: 6) == 40)   // 96 → truncated by the upper limit
    }

    @Test("After retries are exhausted, mark as failed and retain the last Errors")
    func retriesExhausted() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let connector = RecordingConnector(connectorType: "notion")
        connector.fail(with: "Permanent Errors")
        let clock = MutableClock()
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: StubConnectorProvider(connectors: [
                "notion": resolved(id: "notion", type: "notion", connector: connector),
            ]),
            staging: harness.staging,
            configuration: .init(maxRetryCount: 2, baseBackoff: 1),
            clock: { clock.now }
        )
        try await worker.enqueue(itemID: item.id, connectorIDs: ["notion"])

        _ = await worker.runOnce()                 // First failure
        clock.advance(by: 10)
        let second = await worker.runOnce()        // 2nd failure → Reached the limit
        #expect(second.failed == 1)
        let job = try #require(try await harness.outbox.jobs(forItem: item.id).first)
        #expect(job.status == .failed)
        #expect(job.lastError?.contains("giving up") == true)
    }

    @Test("Terminate immediately when the connector is not configured, without meaningless retries")
    func unknownConnectorAbandonsImmediately() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: StubConnectorProvider(connectors: [:]),
            staging: harness.staging
        )
        try await worker.enqueue(itemID: item.id, connectorIDs: ["ghost"])
        let result = await worker.runOnce()
        #expect(result.failed == 1)
        let job = try #require(try await harness.outbox.jobs(forItem: item.id).first)
        #expect(job.status == .failed)
        #expect(job.retryCount == 0)
        #expect(job.lastError?.contains("Connector not configured") == true)
    }

    // MARK: - End-to-end (network-independent)

    @Test("End-to-end: locally mounted connector truly writes to disk and syncs back to the cloud Link")
    func endToEndWithLocalMount() async throws {
        let harness = try await makeHarness()
        let target = try TestSupport.makeTemporaryDirectory("archive")
        // Temporarily save a real file
        let asset = try await harness.staging.stage(
            data: Data("PDF-CONTENT".utf8),
            preferredExtension: "pdf"
        )
        let item = try await insertItem(harness, relativePath: asset.relativePath)

        let config = try JSONSerialization.data(withJSONObject: [
            "namingTemplate": "{Category}/{YYYY}-{MM}/{Title}.{ext}",
            "rootPath": target.path(percentEncoded: false),
        ])
        let connector = LocalCloudMountConnector()
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: StubConnectorProvider(connectors: [
                "obsidian": ResolvedConnector(
                    id: "obsidian",
                    type: "local_mount",
                    record: ConnectorRecord(
                        id: "obsidian",
                        name: "Obsidian",
                        connectorType: "local_mount",
                        configJSON: String(decoding: config, as: UTF8.self)
                    ),
                    connector: connector
                ),
            ]),
            staging: harness.staging
        )

        try await worker.enqueue(itemID: item.id, connectorIDs: ["obsidian"])
        let result = await worker.runOnce()
        #expect(result.succeeded == 1)

        let job = try #require(try await harness.outbox.jobs(forItem: item.id).first)
        #expect(job.status == .succeeded)
        let remoteURL = try #require(job.remoteWebURL.flatMap(URL.init(string:)))
        #expect(remoteURL.pathExtension == "pdf")
        let written = try Data(contentsOf: remoteURL)
        #expect(written == Data("PDF-CONTENT".utf8))
        #expect(remoteURL.path(percentEncoded: false).contains("Technology/"))
    }

    @Test("Observers can receive success and failure events")
    func observersReceiveEvents() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let connector = RecordingConnector(connectorType: "notion")
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: StubConnectorProvider(connectors: [
                "notion": resolved(id: "notion", type: "notion", connector: connector),
            ]),
            staging: harness.staging
        )
        let recorder = EventRecorder()
        await worker.addObserver { event in recorder.append(event) }

        try await worker.enqueue(itemID: item.id, connectorIDs: ["notion"])
        _ = await worker.runOnce()

        let events = recorder.events
        #expect(events.count == 1)
        #expect(events.first?.outcome == .succeeded)
        #expect(events.first?.connectorID == "notion")
    }

    @Test("Multi-target duplicate ID is enqueued only once")
    func duplicateConnectorIDsIgnored() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let connector = RecordingConnector(connectorType: "notion")
        let worker = OutboxSyncWorker(
            database: harness.database,
            connectors: StubConnectorProvider(connectors: [
                "notion": resolved(id: "notion", type: "notion", connector: connector),
            ]),
            staging: harness.staging
        )
        let jobs = try await worker.enqueue(itemID: item.id, connectorIDs: ["notion", "notion"])
        #expect(jobs.count == 1)
    }
}

/// Event collector.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [OutboxSyncEvent] = []

    var events: [OutboxSyncEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: OutboxSyncEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}
