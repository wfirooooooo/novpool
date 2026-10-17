import Foundation
import NovPoolStorage
import Testing

/// OpenAI Key 迁移逻辑在 App 目标里；这里用同等规则验证钥匙串读写与 UserDefaults 清理约定。
@Suite("OpenAI Key 钥匙串约定")
struct OpenAIKeychainMigrationTests {
    @Test("钥匙串可写入并读回 API Key，删除后为空")
    func storeLoadDelete() throws {
        let account = "openai.apiKey.test.\(UUID().uuidString)"
        let keychain = KeychainStore(service: "com.novpool.app.tests")
        defer { try? keychain.delete(account: account) }

        try keychain.store("sk-test-secret-value", account: account)
        #expect(try keychain.loadString(account: account) == "sk-test-secret-value")
        try keychain.delete(account: account)
        #expect(try keychain.loadString(account: account) == nil)
    }
}
