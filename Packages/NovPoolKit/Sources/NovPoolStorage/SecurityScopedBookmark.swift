import Foundation
import NovPoolCore

public struct ResolvedBookmark: Sendable, Equatable {
    public let url: URL
    public let isStale: Bool
}

/// Security-Scoped Bookmark encapsulation.
///
/// The user selects `~/Library/CloudStorage/GoogleDrive-…` on the settings page through `NSOpenPanel`,
/// `~/Library/Mobile Documents/com~apple~CloudDocs` or after the Obsidian vault, the generated
/// Bookmark data is saved to the database; after restoring access permissions during backend synchronization, it is written directly.
public enum SecurityScopedBookmark {
    public static func make(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw NovPoolError.connectorNotConfigured("Could not create security-scoped bookmark: \(error.localizedDescription)")
        }
    }

    public static func resolve(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedBookmark(url: url, isStale: isStale)
        } catch {
            throw NovPoolError.connectorNotConfigured("Could not resolve security-scoped bookmark: \(error.localizedDescription)")
        }
    }

    /// Execute the closure within a secure scope, and access rights will be released after completion.
    public static func withAccess<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        let resolved = try resolve(data)
        let started = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if started { resolved.url.stopAccessingSecurityScopedResource() }
        }
        return try body(resolved.url)
    }
}
