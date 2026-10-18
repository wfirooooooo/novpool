import Foundation

/// Displays the authorization health status of cloud connectors on the settings panel.
public enum ConnectorAuthStatus: Sendable, Equatable {
    case missingCredentials
    case ok
    case needsReauth(String)
    case unchecked

    public var title: String {
        switch self {
        case .missingCredentials: "Unauthorized"
        case .ok: "Credentials valid"
        case .needsReauth: "Re-authorization required"
        case .unchecked: "Not checked"
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
