import Foundation
import NovPoolCore
import Security

/// macOS Keychain access. OAuth token and Notion Integration Token are stored only here.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "com.novpool.app") {
        self.service = service
    }

    public func store(_ secret: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: secret]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw Self.error(status: updateStatus, action: "update")
        }

        var insert = query
        insert[kSecValueData as String] = secret
        // If kSecAttrAccessible is not set: older Keychains on macOS rely on data protection Keychain for support.
        // Apps signed with ad-hoc may directly report errSecParam; the Keychain is already unlocked during the user's login.
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Self.error(status: addStatus, action: "write")
        }
    }

    public func store(_ secret: String, account: String) throws {
        try store(Data(secret.utf8), account: account)
    }

    public func load(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status: status, action: "read")
        }
    }

    public func loadString(account: String) throws -> String? {
        try load(account: account).map { String(decoding: $0, as: UTF8.self) }
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status: status, action: "Delete")
        }
    }

    /// Translate OSStatus into diagnosable information — Keychain is completely unavailable in restricted environments (no login session / sandbox).
    static func error(status: OSStatus, action: String) -> NovPoolError {
        switch status {
        case errSecNotAvailable, errSecInteractionNotAllowed, errSecParam:
            .authenticationRequired(
                "System keychain unavailable (\(action) failed, OSStatus \(status)):"
                    + "Confirm you are in a logged-in GUI session and the sandbox is not blocking keychain access"
            )
        default:
            .authenticationRequired("Keychain \(action) failed (OSStatus \(status))")
        }
    }
}
