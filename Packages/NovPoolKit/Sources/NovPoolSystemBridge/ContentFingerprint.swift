import CryptoKit
import Foundation
import NovPoolCore

/// Unified content fingerprint: write `fileHashSHA256`, used for deduplication of "repeated dragging of the same resource".
///
/// - When there are staged bytes (File / Image / Video), reuse the SHA256 of the staging;
/// - WebLink is hashed according to the normalized URL;
/// - Plain Text / Rich Text hashed by Body.
public enum ContentFingerprint: Sendable {
    /// Calculate fingerprints. Content that cannot be stably identified returns `nil` (no deduplication, stored in the database as usual).
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
            // These types should go to Staging; failure to temporarily store without hash explanation makes deduplication impossible.
            return nil
        }
    }

    /// Normalized URL: lowercase scheme/host, remove fragment, remove trailing slashes (except for the root path).
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
