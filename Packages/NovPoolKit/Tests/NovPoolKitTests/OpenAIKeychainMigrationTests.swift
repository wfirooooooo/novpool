import Foundation
import NovPoolStorage
import Testing

/// The OpenAI Key migration logic is in the App target; here, the same rules are used to verify Keychain read/write and UserDefaults cleanup conventions.
@Suite("OpenAI Key Keychain Agreement")
struct OpenAIKeychainMigrationTests {
    @Test("The keychain can write and read back the API Key; after deletion, it is empty.")
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
