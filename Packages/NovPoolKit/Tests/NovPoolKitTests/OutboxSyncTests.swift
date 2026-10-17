import Foundation
@testable import NovPoolConnectors
import NovPoolCore
import NovPoolStorage
import Testing

/// 记录推送内容的连接器替身。
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
        // NSLock 在 async 上下文里被标记为不可用，因此用同步辅助方法加锁。
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

/// 返回预置连接器的替身。
struct StubConnectorProvider: ConnectorProviding {
    var connectors: [String: ResolvedConnector]

    func resolve(connectorID: String) async -> ResolvedConnector? {
        connectors[connectorID]
    }
}

/// 可推进的时钟。
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

@Suite("发件箱同步：级联、退避与重试")
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
        // 发件箱外键要求连接器先登记（与白皮书 schema 一致），这里把测试用到的都注册好。
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
        title: String = "季度报告",
        relativePath: String? = nil
    ) async throws -> KnowledgeItemRecord {
        let payload = NormalizedPayload(
            contentType: .documentPDF,
            title: title,
            markdownBody: "# 报告正文",
            aiCategory: "技术",
            aiTags: ["报告"],
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

    /// 按连接器 ID 取任务——`jobs(forItem:)` 按更新时间排序，位置会随重试变化，
    /// 用 ID 索引断言才稳定。
    private func jobsByConnector(_ harness: Harness, itemID: UUID) async throws -> [String: OutboxJobRecord] {
        let records = try await harness.outbox.jobs(forItem: itemID)
        return Dictionary(records.map { ($0.connectorID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - 入队顺序与级联依赖

    @Test("入队顺序：需要原始文件的连接器先跑，结构化连接器依赖它")
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

        // 用户即便先选了 Notion，也要被排到网盘之后
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

    @Test("级联：网盘先传文件，链接自动注入下游 Notion 载荷")
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

        // 第一轮：只该跑网盘，Notion 保持等待
        let first = await worker.runOnce()
        #expect(first.succeeded == 1)
        #expect(first.released == 1)
        #expect(notion.payloads.isEmpty)

        // 第二轮：Notion 拿到上游链接
        let second = await worker.runOnce()
        #expect(second.succeeded == 1)
        let downstream = try #require(notion.payloads.first)
        #expect(downstream.upstreamAssetURL?.absoluteString == "https://drive.google.com/file/d/ABC/view")

        let byConnector = try await jobsByConnector(harness, itemID: item.id)
        #expect(byConnector.values.allSatisfy { $0.status == .succeeded })
        #expect(byConnector["gdrive"]?.remoteWebURL == "https://drive.google.com/file/d/ABC/view")
        #expect(byConnector["notion"]?.remoteWebURL != nil)
    }

    @Test("前置任务还没跑完时下游保持阻塞，不会被提前推送")
    func downstreamWaitsForUpstream() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let drive = RecordingConnector(connectorType: "gdrive_api")
        drive.fail(with: "网络不可达")
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

    @Test("前置任务最终失败时，下游带明确原因终止")
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
        drive.fail(with: "配额超限")

        // 把前置任务的退避时间走完，直到重试耗尽
        _ = await worker.runOnce()
        clock.advance(by: 60)
        _ = await worker.runOnce()
        clock.advance(by: 600)
        let final = await worker.runOnce()
        // 第三轮：两个任务都已终止，没有可处理的任务；队列里也不该留下僵尸任务。
        #expect(final.processed == 0)
        #expect(final.waiting == 0)

        let byConnector = try await jobsByConnector(harness, itemID: item.id)
        #expect(byConnector["gdrive"]?.status == .failed)
        #expect(byConnector["gdrive"]?.lastError?.contains("重试 2 次后放弃") == true)
        #expect(byConnector["notion"]?.status == .failed)
        #expect(byConnector["notion"]?.lastError?.contains("前置任务失败") == true)
        #expect(notion.payloads.isEmpty)
    }

    // MARK: - 退避

    @Test("失败按指数退避重试，未到重试时间不会被再次取出")
    func exponentialBackoff() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let connector = RecordingConnector(connectorType: "notion")
        connector.fail(with: "服务端 500")
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

        // 退避期内：不该被取出
        let immediate = await worker.runOnce()
        #expect(immediate.processed == 0)

        clock.advance(by: 3)
        let afterBackoff = await worker.runOnce()
        #expect(afterBackoff.processed == 1)

        let job = try #require(try await harness.outbox.jobs(forItem: item.id).first)
        #expect(job.retryCount == 2)
        #expect(job.lastError?.contains("服务端 500") == true)
    }

    @Test("退避时长按 base * 2^(n-1) 计算并受上限约束")
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
        #expect(await worker.backoffDelay(retryCount: 6) == 40)   // 96 → 被上限截断
    }

    @Test("重试耗尽后标记为 failed 并保留最后错误")
    func retriesExhausted() async throws {
        let harness = try await makeHarness()
        let item = try await insertItem(harness)
        let connector = RecordingConnector(connectorType: "notion")
        connector.fail(with: "永久性错误")
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

        _ = await worker.runOnce()                 // 第 1 次失败
        clock.advance(by: 10)
        let second = await worker.runOnce()        // 第 2 次失败 → 达到上限
        #expect(second.failed == 1)
        let job = try #require(try await harness.outbox.jobs(forItem: item.id).first)
        #expect(job.status == .failed)
        #expect(job.lastError?.contains("重试 2 次后放弃") == true)
    }

    @Test("连接器未配置时直接终止，不做无意义重试")
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
        #expect(job.lastError?.contains("连接器未配置") == true)
    }

    // MARK: - 端到端（不依赖网络）

    @Test("端到端：本地挂载连接器真实落盘并写回云端链接")
    func endToEndWithLocalMount() async throws {
        let harness = try await makeHarness()
        let target = try TestSupport.makeTemporaryDirectory("archive")
        // 暂存一个真实文件
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
        #expect(remoteURL.path(percentEncoded: false).contains("技术/"))
    }

    @Test("观察者能收到成功与失败事件")
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

    @Test("多目标重复 ID 只入队一次")
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

/// 事件收集器。
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
