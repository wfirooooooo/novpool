import Foundation

/// 统一目标端连接器协议（本地云盘挂载 / 网盘 REST / Notion / MCP）。
public protocol DestinationConnector: Sendable {
    /// "local_mount" / "gdrive_api" / "onedrive_api" / "notion" / "mcp"
    var connectorType: String { get }

    /// 校验 Keychain Token 或 Security-Scoped Bookmark 是否仍然有效。
    func validateAuthentication(configJSON: Data) async throws -> Bool

    /// 推送标准化载荷至目标端，返回包含云端直达 URL 的回执。
    func push(payload: NormalizedPayload, configJSON: Data) async throws -> RemoteReceipt
}
