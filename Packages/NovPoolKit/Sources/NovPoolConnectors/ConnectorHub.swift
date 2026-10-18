import Foundation
import NovPoolCore
import NovPoolStorage

/// Parsed connector instance: configuration + available implementation.
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

/// Connector parsing abstraction (facilitates injecting substitutes into the outbox worker).
public protocol ConnectorProviding: Sendable {
    func resolve(connectorID: String) async -> ResolvedConnector?
}

/// Connector hub: Assemble specific implementations according to the types in the `connectors` table, and retrieve sensitive credentials from the Keychain.
/// `FileManager` is not `Sendable`, but it is only used on a synchronous path, so it is explicitly marked.
public struct ConnectorHub: ConnectorProviding, @unchecked Sendable {
    /// The connector type of the original file is required. When cascading across clouds, they run first, and the external link is then injected downstream.
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

    /// Detect whether the cloud connector authorization is still available (enabled status is not required, for display on the settings panel).
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
            return ok ? .ok : .needsReauth("Validation failed; please re-authorize")
        } catch {
            let reason = (error as? NovPoolError)?.errorDescription ?? error.localizedDescription
            return .needsReauth(SecretRedactor.redact(reason))
        }
    }

    /// Connector instance assembly. Credentials come from the Keychain and are never stored in the database.
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
            // Even without credentials, let the connector exist: explicitly report "Authorization required" when pushing, and the user can see the reason in the settings panel.
            return nil
        }
        credentials.provider = provider
        if let tenant = config?.tenant { credentials.tenant = tenant }
        if let path = config?.folderPath { credentials.targetPath = path }
        return credentials
    }
}

/// The non-sensitive configuration of the OAuth connector in `configJSON` (credentials are in the Keychain).
public struct OAuthConnectorConfig: Codable, Sendable, Equatable {
    /// Target directory: use folderID for Drive, use path for OneDrive; leaving it empty indicates the root directory.
    public var folderPath: String?
    /// Microsoft tenant (default common).
    public var tenant: String?

    public init(
        folderPath: String? = nil,
        tenant: String? = nil
    ) {
        self.folderPath = folderPath
        self.tenant = tenant
    }

    /// Encode into configJSON. Do not escape slashes, so that the configuration can be directly viewed with sqlite3 / defaults.
    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
