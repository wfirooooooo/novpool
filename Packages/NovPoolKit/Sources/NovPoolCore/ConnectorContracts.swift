import Foundation

/// Unified target connector protocol (local cloud disk mount / cloud drive REST / Notion / MCP).
public protocol DestinationConnector: Sendable {
    /// "local_mount" / "gdrive_api" / "onedrive_api" / "notion" / "mcp"
    var connectorType: String { get }

    /// Verify whether the Keychain Token or Security-Scoped Bookmark is still valid.
    func validateAuthentication(configJSON: Data) async throws -> Bool

    /// Push standardized payload to the target end and return a receipt containing a cloud direct URL.
    func push(payload: NormalizedPayload, configJSON: Data) async throws -> RemoteReceipt
}
