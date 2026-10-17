import Foundation

/// 极简启动日志：写入 `~/Library/Logs/NovPool.log`，同时镜像到 stderr。
///
/// 存在的理由：用 `open` 启动 app 时 stderr 会被丢弃，启动期故障（数据目录不可写、
/// 建库失败等）会表现为「什么都没发生」，排查成本极高。启动链路上每个关键节点都记一行。
enum NovPoolLog {
    /// 超过该体积就截断重来，避免长期运行把日志撑爆。
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

    /// 每次启动写会话分隔线；旧日志过大时先截断。
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
        append("──────── NovPool 启动 ────────", to: url)
    }

    static func write(_ message: String) {
        FileHandle.standardError.write(Data("NovPool: \(message)\n".utf8))
        lock.lock()
        defer { lock.unlock() }
        append(message, to: fileURL)
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
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }
}
