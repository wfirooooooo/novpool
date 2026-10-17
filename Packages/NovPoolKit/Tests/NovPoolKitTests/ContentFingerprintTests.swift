import Foundation
import NovPoolCore
import Testing
@testable import NovPoolSystemBridge

@Suite("内容指纹与 URL 规范化")
struct ContentFingerprintTests {
    @Test("网页链接忽略大小写 host、fragment 与末尾斜杠")
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

    @Test("纯文本去首尾空白后指纹一致")
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

    @Test("有 Staging 哈希时优先用字节指纹")
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

    @Test("空正文无法生成指纹")
    func emptyTextHasNoFingerprint() {
        let digest = ContentFingerprint.digest(
            for: ResolvedDragContent(contentType: .plainText, text: "   \n"),
            stagedHash: nil,
            resolvedPageURL: nil
        )
        #expect(digest == nil)
    }
}
