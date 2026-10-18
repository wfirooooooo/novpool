import Foundation
import NovPoolCore
import Testing

@Suite("Sensitive information desensitization")
struct SecretRedactorTests {
    @Test("Cover Bearer / sk- / ntn_ / access_token")
    func redactsCommonSecrets() {
        #expect(SecretRedactor.redact("Authorization: Bearer abcdefghijklmnop").contains("***"))
        #expect(!SecretRedactor.redact("key=sk-abcdefghijklmnopqrst").contains("sk-abcdefghijklmnopqrst"))
        #expect(!SecretRedactor.redact("token ntn_abcdefghijklmnopqrst").contains("ntn_abcdefghijklmnopqrst"))
        let json = #"{"access_token":"ya29.secret-value-here","expires_in":3600}"#
        let redacted = SecretRedactor.redact(json)
        #expect(redacted.contains("***"))
        #expect(!redacted.contains("ya29.secret-value-here"))
    }

    @Test("Keep ordinary error messages readable")
    func keepsNormalText() {
        let text = "Refresh token failed (HTTP401):invalid_grant"
        #expect(SecretRedactor.redact(text).contains("invalid_grant"))
    }
}
