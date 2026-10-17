import Foundation
import NovPoolCore
import NovPoolStorage

/// 已解析出的连接器实例：配置 + 可用实现。
public struct ResolvedConnector: Sendable {
    public let id: String
    public let type: String
    public let record: ConnectorRecord
    public let connector: any DestinationConnector

    public init(id: String, type: String, record: ConnectorRecord, connector: any DestinationConnector) {
        self.id = id
        self.type = type
        self.record = record
        self.connector = connector
    }
}

/// 连接器解析抽象（便于给发件箱工作器注入替身）。
public protocol ConnectorProviding: Sendable {
    func resolve(connectorID: String) async -> ResolvedConnector?
}

/// 连接器中枢：按 `connectors` 表里的类型装配具体实现，敏感凭据从 Keychain 取。
/// `FileManager` 不是 `Sendable`，但它只在同步路径上被使用，因此显式标注。
public struct ConnectorHub: ConnectorProviding, @unchecked Sendable {
    /// 需要原始文件的连接器类型。跨云级联时它们先跑，外链再注入下游。
    public static let fileFirstTypes: Set<String> = ["gdrive_api", "onedrive_api", "local_mount"]

    private let repository: ConnectorRepository
    private let keychain: KeychainStore
    private let transport: any HTTPTransport
    private let fileManager: FileManager

    public init(
        repository: ConnectorRepository,
        keychain: KeychainStore = KeychainStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.keychain = keychain
        self.transport = transport
        self.fileManager = fileManager
    }

    public func resolve(connectorID: String) async -> ResolvedConnector? {
        guard let record = try? await repository.fetch(id: connectorID), record.isEnabled else {
            return nil
        }
        guard let connector = makeConnector(for: record) else { return nil }
        return ResolvedConnector(
            id: record.id,
            type: record.connectorType,
            record: record,
            connector: connector
        )
    }

    /// 探测云连接器授权是否仍可用（不要求启用状态，供设置面板展示）。
    public func probeAuthentication(connectorID: String) async -> ConnectorAuthStatus {
        guard let record = try? await repository.fetch(id: connectorID) else {
            return .unchecked
        }
        switch record.connectorType {
        case "notion", "gdrive_api", "onedrive_api":
            break
        default:
            return .unchecked
        }
        guard let account = record.keychainAccountRef,
              let secret = try? keychain.load(account: account),
              !secret.isEmpty else {
            return .missingCredentials
        }
        guard let connector = makeConnector(for: record) else {
            return .missingCredentials
        }
        do {
            let ok = try await connector.validateAuthentication(configJSON: record.configData)
            return ok ? .ok : .needsReauth("校验未通过，请重新授权")
        } catch {
            let reason = (error as? NovPoolError)?.errorDescription ?? error.localizedDescription
            return .needsReauth(SecretRedactor.redact(reason))
        }
    }

    /// 连接器实例装配。凭据来自 Keychain，绝不落库。
    func makeConnector(for record: ConnectorRecord) -> (any DestinationConnector)? {
        switch record.connectorType {
        case "local_mount":
            return LocalCloudMountConnector(fileManager: fileManager)

        case "notion":
            let token = record.keychainAccountRef.flatMap { try? keychain.loadString(account: $0) } ?? nil
            return NotionConnector(token: token, transport: transport)

        case "gdrive_api":
            return GoogleDriveAPIConnector(
                credentials: oauthCredentials(for: record, provider: .google),
                transport: transport,
                fileManager: fileManager
            )

        case "onedrive_api":
            return OneDriveAPIConnector(
                credentials: oauthCredentials(for: record, provider: .microsoft),
                transport: transport,
                fileManager: fileManager
            )

        default:
            return nil
        }
    }

    private func oauthCredentials(
        for record: ConnectorRecord,
        provider: OAuthProviderKind
    ) -> OAuthCredentials? {
        let config = try? JSONDecoder().decode(OAuthConnectorConfig.self, from: record.configData)
        guard let account = record.keychainAccountRef,
              let secret = try? keychain.load(account: account),
              var credentials = OAuthCredentials.decoded(secret) else {
            // 没凭据也让连接器存在：push 时明确报「需要先授权」，用户能在设置面板看到原因。
            return nil
        }
        credentials.provider = provider
        if let tenant = config?.tenant { credentials.tenant = tenant }
        if let path = config?.folderPath { credentials.targetPath = path }
        return credentials
    }
}

/// OAuth 连接器在 `configJSON` 里的非敏感配置（凭据在 Keychain）。
public struct OAuthConnectorConfig: Codable, Sendable, Equatable {
    /// 目标目录：Drive 用 folderID，OneDrive 用路径；为空表示根目录。
    public var folderPath: String?
    /// Microsoft 租户（默认 common）。
    public var tenant: String?

    public init(
        folderPath: String? = nil,
        tenant: String? = nil
    ) {
        self.folderPath = folderPath
        self.tenant = tenant
    }

    /// 编码成 configJSON。不转义斜杠，方便直接用 sqlite3 / defaults 查看配置。
    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
