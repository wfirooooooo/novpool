import Foundation
import NovPoolCore

public struct ResolvedBookmark: Sendable, Equatable {
    public let url: URL
    public let isStale: Bool
}

/// Security-Scoped Bookmark 封装。
///
/// 用户在设置页通过 `NSOpenPanel` 选定 `~/Library/CloudStorage/GoogleDrive-…`、
/// `~/Library/Mobile Documents/com~apple~CloudDocs` 或 Obsidian 库之后，把生成的
/// 书签数据落库；后台同步时恢复访问权限后直接写入。
public enum SecurityScopedBookmark {
    public static func make(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw NovPoolError.connectorNotConfigured("无法创建安全作用域书签：\(error.localizedDescription)")
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
            throw NovPoolError.connectorNotConfigured("无法解析安全作用域书签：\(error.localizedDescription)")
        }
    }

    /// 在安全作用域内执行闭包，结束后必定释放访问权限。
    public static func withAccess<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        let resolved = try resolve(data)
        let started = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if started { resolved.url.stopAccessingSecurityScopedResource() }
        }
        return try body(resolved.url)
    }
}
