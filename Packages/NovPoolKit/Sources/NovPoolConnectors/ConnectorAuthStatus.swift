import Foundation

/// 设置面板展示的云连接器授权健康状态。
public enum ConnectorAuthStatus: Sendable, Equatable {
    case missingCredentials
    case ok
    case needsReauth(String)
    case unchecked

    public var title: String {
        switch self {
        case .missingCredentials: "未授权"
        case .ok: "凭据有效"
        case .needsReauth: "需重新授权"
        case .unchecked: "未检查"
        }
    }

    public var detail: String? {
        if case .needsReauth(let reason) = self { return reason }
        return nil
    }

    public var needsAttention: Bool {
        switch self {
        case .missingCredentials, .needsReauth: true
        case .ok, .unchecked: false
        }
    }
}
