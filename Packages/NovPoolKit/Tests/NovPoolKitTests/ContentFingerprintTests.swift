import Foundation
import NovPoolCore
import Testing
@testable import NovPoolSystemBridge

@Suite("Content Fingerprinting and URL Normalization")
struct ContentFingerprintTests {
    @Test("WebLink ignores case for host, fragment, and trailing slash")
    func canonicalWebLink() {
        let a = ContentFingerprint.digest(
            for: ResolvedDragContent(
                contentType: .webLink,
                pageURL: URL(string: "https://Example.com/foo/#x")
            ),
            stagedHash: nil,
            resolvedPageURL: URL(string: "https://Example.com/foo/#x")
        )
        let b = ContentFingerprint.digest(
            for: ResolvedDragContent(
                contentType: .webLink,
                pageURL: URL(string: "https://example.com/foo/")
            ),
            stagedHash: nil,
            resolvedPageURL: URL(string: "https://example.com/foo/")
        )
        #expect(a == b)
        #expect(a?.count == 64)
    }

    @Test("After removing the leading and trailing whitespace from the plain text, the fingerprints are identical")
    func plainTextTrimmed() {
        let a = ContentFingerprint.digest(
            for: ResolvedDragContent(contentType: .plainText, text: "  hello\n"),
            stagedHash: nil,
            resolvedPageURL: nil
        )
        let b = ContentFingerprint.digest(
            for: ResolvedDragContent(contentType: .plainText, text: "hello"),
            stagedHash: nil,
            resolvedPageURL: nil
        )
        #expect(a == b)
    }

    @Test("When there is a Staging hash, prioritize using the byte fingerprint")
    func stagedHashWins() {
        let digest = ContentFingerprint.digest(
            for: ResolvedDragContent(
                contentType: .webLink,
                pageURL: URL(string: "https://example.com")
            ),
            stagedHash: "abc123",
            resolvedPageURL: URL(string: "https://example.com")
        )
        #expect(digest == "abc123")
    }

    @Test("Empty Body cannot generate fingerprint")
    func emptyTextHasNoFingerprint() {
        let digest = ContentFingerprint.digest(
            for: ResolvedDragContent(contentType: .plainText, text: "   \n"),
            stagedHash: nil,
            resolvedPageURL: nil
        )
        #expect(digest == nil)
    }
}
