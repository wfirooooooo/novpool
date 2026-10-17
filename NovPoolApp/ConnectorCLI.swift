import Foundation
import NovPoolConnectors
import NovPoolCore
import NovPoolStorage

/// 连接器与同步的命令行入口。
///
/// 图形界面只覆盖「本地归档目录」这一条最常用路径；云端连接器（Notion / Drive / OneDrive）
/// 需要凭据，走命令行登记最直接，也便于脚本化与排障：
///
///     NovPool --list-connectors
///     NovPool --add-connector '{"id":"notion","name":"Notion","type":"notion","config":{"databaseID":"…"},"token":"ntn_…"}'
///     NovPool --add-connector '{"id":"gdrive","name":"Google Drive","type":"gdrive_api","config":{"folderID":"…"},"oauth":{"provider":"google","clientID":"…","clientSecret":"…","refreshToken":"…"}}'
///     NovPool --remove-connector notion
///     NovPool --sync-now
enum ConnectorCLI {
    struct Request: Decodable {
        var id: String
        var name: String?
        var type: String
        /// 非敏感配置，原样写入 `connectors.configJSON`。
        var config: JSONValue?
        /// Notion 等 Token 型连接器的凭据（写入 Keychain）。
        var token: String?
        /// OAuth 凭据（写入 Keychain）。
        var oauth: OAuthCredentials?
    }

    /// 任意 JSON 值，用于把 `config` 原样序列化。
    enum JSONValue: Codable {
        case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
            else { self = .array(try container.decode([JSONValue].self)) }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            }
        }

        var jsonString: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// 返回 nil 表示当前参数不需要 CLI 处理。
    static func run(arguments: [String]) -> Int32? {
        guard let command = arguments.first(where: { $0.hasPrefix("--") && $0 != "--selftest" }) else {
            return nil
        }
        let value = { (flag: String) -> String? in
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        switch command {
        case "--list-connectors":
            return execute { try await listConnectors() }
        case "--add-connector":
            guard let json = value("--add-connector") else {
                print("用法：--add-connector '<json>'")
                return 2
            }
            return execute { try await addConnector(json) }
        case "--remove-connector":
            guard let id = value("--remove-connector") else {
                print("用法：--remove-connector <id>")
                return 2
            }
            return execute { try await removeConnector(id) }
        case "--sync-now":
            return execute { try await syncNow() }
        default:
            return nil
        }
    }

    // MARK: - 命令实现

    private static func listConnectors() async throws -> Int32 {
        let context = try makeContext()
        let connectors = try await context.connectorRepository.list()
        if connectors.isEmpty {
            print("还没有登记任何连接器。")
        } else {
            print("连接器（\(connectors.count)）：")
            for connector in connectors {
                let state = connector.isEnabled ? "启用" : "停用"
                let credential = connector.keychainAccountRef == nil ? "无凭据" : "凭据在钥匙串"
                print("  [\(state)] \(connector.id)  \(connector.connectorType)  \(connector.name)  \(credential)")
            }
        }

        let repository = OutboxRepository(database: context.database)
        let counts = try await repository.statusCounts()
        if counts.isEmpty {
            print("同步队列为空。")
        } else {
            let summary = counts
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue.lowercased()) \($0.value)" }
                .joined(separator: " · ")
            print("同步队列：\(summary)")
        }
        return 0
    }

    private static func addConnector(_ json: String) async throws -> Int32 {
        let context = try makeContext()
        guard let data = json.data(using: .utf8) else { throw NovPoolError.connectorNotConfigured("参数不是有效文本") }
        let request = try JSONDecoder().decode(Request.self, from: data)

        let keychain = KeychainStore()
        var account: String?
        if let oauth = request.oauth {
            let name = "\(request.id).oauth"
            try keychain.store(try oauth.encoded(), account: name)
            account = name
        } else if let token = request.token, !token.isEmpty {
            let name = "\(request.id).token"
            try keychain.store(token, account: name)
            account = name
        }

        let record = ConnectorRecord(
            id: request.id,
            name: request.name ?? request.id,
            connectorType: request.type,
            keychainAccountRef: account,
            configJSON: request.config?.jsonString ?? "{}"
        )
        try await context.connectorRepository.upsert(record)
        print("已登记连接器：\(record.id)（\(record.connectorType)）")
        if account != nil { print("凭据已写入系统钥匙串：\(account!)") }

        // 立即校验一次，让「id/密钥写错」当场暴露，而不是等到第一次同步才失败。
        let hub = ConnectorHub(repository: context.connectorRepository, keychain: keychain)
        if let resolved = await hub.resolve(connectorID: record.id) {
            let valid = (try? await resolved.connector.validateAuthentication(configJSON: resolved.record.configData)) ?? false
            print(valid ? "鉴权校验通过。" : "鉴权校验未通过：请检查配置与凭据（离线环境无法验证云端连接）。")
        } else {
            print("警告：连接器类型 \(record.connectorType) 未实现，同步时会跳过。")
        }
        return 0
    }

    private static func removeConnector(_ id: String) async throws -> Int32 {
        let context = try makeContext()
        guard let record = try await context.connectorRepository.fetch(id: id) else {
            print("未找到连接器：\(id)")
            return 1
        }
        if let account = record.keychainAccountRef {
            try? KeychainStore().delete(account: account)
        }
        try await context.connectorRepository.delete(id: id)
        print("已删除连接器：\(id)")
        return 0
    }

    private static func syncNow() async throws -> Int32 {
        let context = try makeContext()
        let hub = ConnectorHub(repository: context.connectorRepository)
        let worker = OutboxSyncWorker(
            database: context.database,
            connectors: hub,
            staging: try StagingStore(root: NovPoolPaths.stagingRoot())
        )
        let result = await worker.runOnce()
        print("本轮：处理 \(result.processed)，成功 \(result.succeeded)，失败 \(result.failed)，"
            + "等待前置 \(result.waiting)，解锁下游 \(result.released)")

        let repository = OutboxRepository(database: context.database)
        for job in try await repository.dueJobs(now: Date(), limit: 5) {
            print("  待重试：\(job.connectorID) 第 \(job.retryCount) 次 · \(job.lastError ?? "")")
        }
        return result.failed > 0 ? 1 : 0
    }

    // MARK: - 上下文

    private struct Context {
        let database: NovPoolDatabase
        let connectorRepository: ConnectorRepository
    }

    private static func makeContext() throws -> Context {
        let database = try NovPoolDatabase(
            path: NovPoolPaths.databaseURL().path(percentEncoded: false)
        )
        // CLI 可能先于 GUI 首次运行，因此这里也要保证 schema 已就绪。
        let semaphore = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        Task.detached {
            do {
                try await SchemaMigrator.migrate(database)
            } catch {
                failure.message = "\(error)"
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let message = failure.message {
            throw NovPoolError.database("迁移失败：\(message)")
        }
        return Context(database: database, connectorRepository: ConnectorRepository(database: database))
    }

    private final class FailureBox: @unchecked Sendable {
        var message: String?
    }

    /// CLI 是同步入口（无 GUI），因此用信号量等待异步实现。
    /// `work` 必须显式 `@Sendable`：它会跨进 detached task 执行。
    private static func execute(_ work: @escaping @Sendable () async throws -> Int32) -> Int32 {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.code = try await work()
            } catch {
                print("失败：\((error as? NovPoolError)?.errorDescription ?? "\(error)")")
                box.code = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.code
    }

    private final class ResultBox: @unchecked Sendable {
        var code: Int32 = 1
    }
}
