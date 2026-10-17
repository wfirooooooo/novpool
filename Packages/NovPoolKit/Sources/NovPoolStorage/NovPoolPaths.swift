import Foundation
import NovPoolCore

/// 应用数据目录（`~/Library/Application Support/NovPool`）。
public enum NovPoolPaths {
    /// 数据根目录的环境变量覆盖：`NOVPOOL_DATA_DIR=/path`。
    /// 用于自检、CI 与多份数据隔离（默认走 `~/Library/Application Support/NovPool`）。
    public static let dataDirectoryOverrideKey = "NOVPOOL_DATA_DIR"

    /// 实际使用的数据根目录（考虑环境变量覆盖）。
    public static func dataRoot(fileManager: FileManager = .default) throws -> URL {
        let override = ProcessInfo.processInfo.environment[dataDirectoryOverrideKey]
        if let override, !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        return try applicationSupport(fileManager: fileManager)
    }

    /// 解析应用数据目录。**只拼路径，不保证存在**——需要可写目录时用 `prepareApplicationSupport()`。
    public static func applicationSupport(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "NovPool", directoryHint: .isDirectory)
    }

    /// 创建应用数据目录（含中间层级）并返回它。
    ///
    /// 首次启动必须有这一步：SQLite 不会为数据库文件创建父目录，
    /// 目录缺失时 `sqlite3_open_v2` 直接 CANTOPEN，整个启动流程会在这里断掉。
    @discardableResult
    public static func prepareApplicationSupport(fileManager: FileManager = .default) throws -> URL {
        let directory = try dataRoot(fileManager: fileManager)
        return try ensureDirectory(at: directory, fileManager: fileManager)
    }

    /// 幂等地创建目录（已存在则什么都不做）。
    @discardableResult
    public static func ensureDirectory(at url: URL, fileManager: FileManager = .default) throws -> URL {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw NovPoolError.stagingFailure("无法创建数据目录 \(url.path(percentEncoded: false))：\(error.localizedDescription)")
        }
        return url
    }

    public static func stagingRoot(fileManager: FileManager = .default) throws -> URL {
        try dataRoot(fileManager: fileManager)
            .appending(path: "Staging", directoryHint: .isDirectory)
    }

    public static func databaseURL(fileManager: FileManager = .default) throws -> URL {
        try dataRoot(fileManager: fileManager).appending(path: "novpool.sqlite")
    }
}
