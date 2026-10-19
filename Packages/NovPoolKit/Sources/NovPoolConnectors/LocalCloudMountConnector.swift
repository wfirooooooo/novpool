import Foundation
import NovPoolCore
import NovPoolStorage

/// Local cloud disk mount directory direct connector (zero-authentication high-speed mode).
///
/// The target directory can be `~/Library/CloudStorage/GoogleDrive-…`,
/// `~/Library/Mobile Documents/com~apple~CloudDocs`,`~/Library/CloudStorage/OneDrive-…`
/// Or any local Obsidian vault. In a production environment, access permissions are persisted through secure scope bookmarks.
/// `FileManager` itself is not `Sendable`, but its file system operations are thread-safe, and this type is only used in
/// `push` internally synchronizes using this instance, so it is explicitly marked with `@unchecked Sendable`.
public struct LocalCloudMountConnector: DestinationConnector, @unchecked Sendable {
    public struct Config: Codable, Sendable, Equatable {
        public var namingTemplate: String
        /// Security-Scoped Bookmark (Base64), used in production environment.
        public var rootBookmarkBase64: String?
        /// Direct path, used for non-sandbox environments and unit testing.
        public var rootPath: String?

        public init(
            namingTemplate: String = NamingTemplate.defaultTemplate,
            rootBookmarkBase64: String? = nil,
            rootPath: String? = nil
        ) {
            self.namingTemplate = namingTemplate
            self.rootBookmarkBase64 = rootBookmarkBase64
            self.rootPath = rootPath
        }
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public var connectorType: String { "local_mount" }

    public func validateAuthentication(configJSON: Data) async throws -> Bool {
        do {
            let root = try resolveRoot(configJSON)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: root.path(percentEncoded: false),
                isDirectory: &isDirectory
            )
            return exists && isDirectory.boolValue
        } catch {
            return false
        }
    }

    public func push(payload: NormalizedPayload, configJSON: Data) async throws -> RemoteReceipt {
        let config = try decodeConfig(configJSON)
        let extensionHint = Self.fileExtension(for: payload, fallbackURL: payload.localStagedURL)
        let relativePath = NamingTemplate(template: config.namingTemplate).render(
            payload: payload,
            fileExtension: extensionHint
        )

        if let bookmarkBase64 = config.rootBookmarkBase64, let data = Data(base64Encoded: bookmarkBase64) {
            let destination = try SecurityScopedBookmark.withAccess(data) { root -> URL in
                try self.write(payload: payload, relativePath: relativePath, root: root)
            }
            return RemoteReceipt(
                connectorID: "local_mount",
                remoteItemID: relativePath,
                remoteWebURL: destination
            )
        }

        let root = try resolveRoot(configJSON)
        let destination = try write(payload: payload, relativePath: relativePath, root: root)
        return RemoteReceipt(
            connectorID: "local_mount",
            remoteItemID: relativePath,
            remoteWebURL: destination
        )
    }

    // MARK: - Internals

    static func fileExtension(for payload: NormalizedPayload, fallbackURL: URL?) -> String {
        switch payload.contentType {
        case .documentPDF: "pdf"
        case .image: fallbackURL?.pathExtension.isEmpty == false ? fallbackURL!.pathExtension : "png"
        case .video: fallbackURL?.pathExtension.isEmpty == false ? fallbackURL!.pathExtension : "mp4"
        case .genericFile: fallbackURL?.pathExtension.isEmpty == false ? fallbackURL!.pathExtension : "dat"
        case .richHTML, .plainText, .webLink, .digest: "md"
        }
    }

    private func decodeConfig(_ configJSON: Data) throws -> Config {
        do {
            return try JSONDecoder().decode(Config.self, from: configJSON)
        } catch {
            throw NovPoolError.connectorNotConfigured("local_mount config parse failed: \(error.localizedDescription)")
        }
    }

    private func resolveRoot(_ configJSON: Data) throws -> URL {
        let config = try decodeConfig(configJSON)
        if let path = config.rootPath {
            return URL(filePath: path)
        }
        if let bookmarkBase64 = config.rootBookmarkBase64, let data = Data(base64Encoded: bookmarkBase64) {
            return try SecurityScopedBookmark.resolve(data).url
        }
        throw NovPoolError.connectorNotConfigured("local_mount target directory not configured")
    }

    @discardableResult
    private func write(payload: NormalizedPayload, relativePath: String, root: URL) throws -> URL {
        let destination = root.appending(path: relativePath)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let stagedURL = payload.localStagedURL,
               fileManager.fileExists(atPath: stagedURL.path(percentEncoded: false)) {
                if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: stagedURL, to: destination)
            } else {
                try Data(Self.markdownDocument(for: payload).utf8)
                    .write(to: destination, options: .atomic)
            }
        } catch {
            throw NovPoolError.stagingFailure("Failed to write to local cloud mount: \(error.localizedDescription)")
        }
        return destination
    }

    /// When there is no original file, generate a Markdown archive with YAML Front Matter.
    static func markdownDocument(for payload: NormalizedPayload) -> String {
        var lines = [
            "---",
            "title: \(payload.title)",
            "contentType: \(payload.contentType.rawValue)",
            "capturedAt: \(SQLiteDate.string(from: payload.sourceContext.capturedAt))",
        ]
        if let url = payload.sourceContext.pageURL {
            lines.append("source: \(url.absoluteString)")
        } else if let upstream = payload.upstreamAssetURL {
            lines.append("source: \(upstream.absoluteString)")
        }
        if let category = payload.aiCategory {
            lines.append("category: \(category)")
        }
        if !payload.aiTags.isEmpty {
            lines.append("tags: [\(payload.aiTags.joined(separator: ", "))]")
        }
        lines.append("---")
        lines.append("")
        if let summary = payload.aiSummary {
            lines.append("> \(summary)")
            lines.append("")
        }
        if let body = payload.markdownBody {
            lines.append(body)
        } else if let ocr = payload.ocrText {
            lines.append(ocr)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
