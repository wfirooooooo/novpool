import Foundation
import NovPoolCore
import Security

/// macOS 钥匙串访问。OAuth token 与 Notion Integration Token 只存这里。
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
            throw Self.error(status: updateStatus, action: "更新")
        }

        var insert = query
        insert[kSecValueData as String] = secret
        // 不设置 kSecAttrAccessible：macOS 的旧钥匙串对它的支持依赖数据保护钥匙串，
        // ad-hoc 签名的 app 上可能直接报 errSecParam；登录钥匙串在用户登录期间本就是解锁的。
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Self.error(status: addStatus, action: "写入")
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
            throw Self.error(status: status, action: "读取")
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
            throw Self.error(status: status, action: "删除")
        }
    }

    /// 把 OSStatus 翻成可诊断的信息——钥匙串在受限环境（无登录会话 / 沙盒）里是整体不可用的。
    static func error(status: OSStatus, action: String) -> NovPoolError {
        switch status {
        case errSecNotAvailable, errSecInteractionNotAllowed, errSecParam:
            .authenticationRequired(
                "系统钥匙串不可用（\(action)失败，OSStatus \(status)）："
                    + "请确认在已登录的图形会话中运行，且沙盒未拦截 keychain 访问"
            )
        default:
            .authenticationRequired("钥匙串\(action)失败（OSStatus \(status)）")
        }
    }
}
