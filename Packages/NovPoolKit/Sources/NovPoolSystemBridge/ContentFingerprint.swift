import CryptoKit
import Foundation
import NovPoolCore

/// 统一内容指纹：写入 `fileHashSHA256`，用于「同一资源重复拖拽」去重。
///
/// - 有暂存字节（文件 / 图片 / 视频）时复用 Staging 的 SHA256；
/// - 网页链接按规范化 URL 哈希；
/// - 纯文本 / 富文本按正文哈希。
public enum ContentFingerprint: Sendable {
    /// 计算指纹。无法稳定标识的内容返回 `nil`（不去重，照常入库）。
    public static func digest(
        for content: ResolvedDragContent,
        stagedHash: String?,
        resolvedPageURL: URL?
    ) -> String? {
        if let stagedHash, !stagedHash.isEmpty {
            return stagedHash
        }

        switch content.contentType {
        case .webLink:
            guard let url = resolvedPageURL ?? content.pageURL else { return nil }
            let key = "weblink\n\(canonicalURLString(url))"
            return sha256Hex(Data(key.utf8))

        case .plainText:
            guard let body = normalizedText(content.text) else { return nil }
            return sha256Hex(Data("plaintext\n\(body)".utf8))

        case .richHTML:
            guard let body = normalizedText(content.html) ?? normalizedText(content.text) else {
                return nil
            }
            return sha256Hex(Data("richhtml\n\(body)".utf8))

        case .image, .video, .documentPDF, .genericFile:
            // 这些类型应走 Staging；没有哈希说明暂存失败，无法去重。
            return nil
        }
    }

    /// 规范化 URL：小写 scheme/host、去掉 fragment、去掉末尾多余 `/`（根路径除外）。
    public static func canonicalURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        let path = components.path
        if path.count > 1, path.hasSuffix("/") {
            components.path = String(path.dropLast())
        }
        return components.string ?? url.absoluteString
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
