import Foundation
import NovPoolCore
import Testing

@Suite("敏感信息脱敏")
struct SecretRedactorTests {
    @Test("遮盖 Bearer / sk- / ntn_ / access_token")
    func redactsCommonSecrets() {
        #expect(SecretRedactor.redact("Authorization: Bearer abcdefghijklmnop").contains("***"))
        #expect(!SecretRedactor.redact("key=sk-abcdefghijklmnopqrst").contains("sk-abcdefghijklmnopqrst"))
        #expect(!SecretRedactor.redact("token ntn_abcdefghijklmnopqrst").contains("ntn_abcdefghijklmnopqrst"))
        let json = #"{"access_token":"ya29.secret-value-here","expires_in":3600}"#
        let redacted = SecretRedactor.redact(json)
        #expect(redacted.contains("***"))
        #expect(!redacted.contains("ya29.secret-value-here"))
    }

    @Test("普通错误文案保持可读")
    func keepsNormalText() {
        let text = "刷新令牌失败（HTTP 401）：invalid_grant"
        #expect(SecretRedactor.redact(text).contains("invalid_grant"))
    }
}
