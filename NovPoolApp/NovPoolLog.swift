import Foundation
import NovPoolCore

/// Minimal startup log: writes `~/Library/Logs/NovPool.log` and mirrors to stderr.
///
/// Why it exists: launching via `open` discards stderr, so early failures (unwritable
/// data dir, DB setup, etc.) look like “nothing happened”. Log every critical bootstrap step.
enum NovPoolLog {
    /// Truncate and start fresh past this size so long runs do not balloon the log.
    private static let maximumBytes = 512 * 1024
    private static let lock = NSLock()

    static var fileURL: URL {
        let library = (try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(filePath: NSTemporaryDirectory())
        return library
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "NovPool.log")
    }

    static var path: String { fileURL.path(percentEncoded: false) }

    /// Write a session separator on each launch; truncate first if the old log is too large.
    static func startSession() {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        if let size = attributes?[.size] as? Int, size > maximumBytes {
            try? FileManager.default.removeItem(at: url)
        }
        append("──────── NovPool start ────────", to: url)
    }

    static func write(_ message: String) {
        let safe = SecretRedactor.redact(message)
        FileHandle.standardError.write(Data("NovPool: \(safe)\n".utf8))
        lock.lock()
        defer { lock.unlock() }
        append(safe, to: fileURL)
    }

    private static func append(_ message: String, to url: URL) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
