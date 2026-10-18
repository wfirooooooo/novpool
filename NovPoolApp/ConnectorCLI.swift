import Foundation
import NovPoolConnectors
import NovPoolCore
import NovPoolStorage

/// Connector and sync CLI entry points.
///
/// The GUI covers the common “local archive folder” path; cloud connectors
/// (Notion / Drive / OneDrive) need credentials—register them on the CLI for scripting
/// and troubleshooting:
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
        /// Non-sensitive config, stored as-is in `connectors.configJSON`.
        var config: JSONValue?
        /// Token credentials for Notion-style connectors (Keychain).
        var token: String?
        /// OAuth credentials (Keychain).
        var oauth: OAuthCredentials?
    }

    /// Arbitrary JSON value so `config` can be re-serialized verbatim.
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

    /// Returns nil when the current arguments do not need CLI handling.
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
                print("Usage: --add-connector '<json>'")
                return 2
            }
            return execute { try await addConnector(json) }
        case "--remove-connector":
            guard let id = value("--remove-connector") else {
                print("Usage: --remove-connector <id>")
                return 2
            }
            return execute { try await removeConnector(id) }
        case "--sync-now":
            return execute { try await syncNow() }
        default:
            return nil
        }
    }

    // MARK: - Command implementations

    private static func listConnectors() async throws -> Int32 {
        let context = try makeContext()
        let connectors = try await context.connectorRepository.list()
        if connectors.isEmpty {
            print("No connectors registered.")
        } else {
            print("Connectors (\(connectors.count)):")
            for connector in connectors {
                let state = connector.isEnabled ? "enabled" : "disabled"
                let credential = connector.keychainAccountRef == nil ? "no credentials" : "credentials in Keychain"
                print("  [\(state)] \(connector.id)  \(connector.connectorType)  \(connector.name)  \(credential)")
            }
        }

        let repository = OutboxRepository(database: context.database)
        let counts = try await repository.statusCounts()
        if counts.isEmpty {
            print("Sync queue empty.")
        } else {
            let summary = counts
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue.lowercased()) \($0.value)" }
                .joined(separator: " · ")
            print("Sync queue: \(summary)")
        }
        return 0
    }

    private static func addConnector(_ json: String) async throws -> Int32 {
        let context = try makeContext()
        guard let data = json.data(using: .utf8) else { throw NovPoolError.connectorNotConfigured("Argument is not valid text") }
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
        print("Registered connector: \(record.id) (\(record.connectorType))")
        if account != nil { print("Credentials stored in Keychain: \(account!)") }

        // Validate immediately so bad ids/secrets surface here, not on first sync.
        let hub = ConnectorHub(repository: context.connectorRepository, keychain: keychain)
        if let resolved = await hub.resolve(connectorID: record.id) {
            let valid = (try? await resolved.connector.validateAuthentication(configJSON: resolved.record.configData)) ?? false
            print(valid ? "Auth check passed." : "Auth check failed: verify config and credentials (offline cannot verify cloud).")
        } else {
            print("Warning: connector type \(record.connectorType) is not implemented; sync will skip it.")
        }
        return 0
    }

    private static func removeConnector(_ id: String) async throws -> Int32 {
        let context = try makeContext()
        guard let record = try await context.connectorRepository.fetch(id: id) else {
            print("Connector not found: \(id)")
            return 1
        }
        if let account = record.keychainAccountRef {
            try? KeychainStore().delete(account: account)
        }
        try await context.connectorRepository.delete(id: id)
        print("Deleted connector: \(id)")
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
        print("This run: processed \(result.processed), succeeded \(result.succeeded), failed \(result.failed), "
            + "waiting \(result.waiting), released \(result.released)")

        let repository = OutboxRepository(database: context.database)
        for job in try await repository.dueJobs(now: Date(), limit: 5) {
            print("  Retry pending: \(job.connectorID) attempt \(job.retryCount) · \(job.lastError ?? "")")
        }
        return result.failed > 0 ? 1 : 0
    }

    // MARK: - Context

    private struct Context {
        let database: NovPoolDatabase
        let connectorRepository: ConnectorRepository
    }

    private static func makeContext() throws -> Context {
        let database = try NovPoolDatabase(
            path: NovPoolPaths.databaseURL().path(percentEncoded: false)
        )
        // CLI may run before first GUI launch; ensure schema is ready.
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
            throw NovPoolError.database("Migration failed: \(message)")
        }
        return Context(database: database, connectorRepository: ConnectorRepository(database: database))
    }

    private final class FailureBox: @unchecked Sendable {
        var message: String?
    }

    /// CLI is a sync entry (no GUI), so wait on a semaphore for async work.
    /// `work` must be `@Sendable` because it crosses into a detached task.
    private static func execute(_ work: @escaping @Sendable () async throws -> Int32) -> Int32 {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.code = try await work()
            } catch {
                print("Failed: \((error as? NovPoolError)?.errorDescription ?? "\(error)")")
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
