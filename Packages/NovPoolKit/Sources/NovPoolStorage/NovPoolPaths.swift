import Foundation
import NovPoolCore

/// Application data directory (`~/Library/Application Support/NovPool`).
public enum NovPoolPaths {
    /// Environment variable override for the data root directory: `NOVPOOL_DATA_DIR=/path`.
    /// Used for self-checking, CI, and isolating multiple sets of data (by default, it uses `~/Library/Application Support/NovPool`).
    public static let dataDirectoryOverrideKey = "NOVPOOL_DATA_DIR"

    /// The root directory of the actual data used (considering environment variable overrides).
    public static func dataRoot(fileManager: FileManager = .default) throws -> URL {
        let override = ProcessInfo.processInfo.environment[dataDirectoryOverrideKey]
        if let override, !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        return try applicationSupport(fileManager: fileManager)
    }

    /// Parse the application data directory. **Path only, existence not guaranteed** — use `prepareApplicationSupport()` when a writable directory is needed.
    public static func applicationSupport(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "NovPool", directoryHint: .isDirectory)
    }

    /// Create the application data directory (including intermediate levels) and return it.
    ///
    /// This step is required on the first launch: SQLite will not create parent directories for the database file.
    /// When the directory is missing, `sqlite3_open_v2` directly returns CANTOPEN, and the entire startup process will break here.
    @discardableResult
    public static func prepareApplicationSupport(fileManager: FileManager = .default) throws -> URL {
        let directory = try dataRoot(fileManager: fileManager)
        return try ensureDirectory(at: directory, fileManager: fileManager)
    }

    /// Idempotently create a directory (do nothing if it already exists).
    @discardableResult
    public static func ensureDirectory(at url: URL, fileManager: FileManager = .default) throws -> URL {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw NovPoolError.stagingFailure("Could not create data directory\(url.path(percentEncoded: false)): \(error.localizedDescription)")
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
