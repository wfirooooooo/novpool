import CryptoKit
import Foundation
import NovPoolCore

/// Temporary asset description. `relativePath` is based on the Staging root directory, write to the database.
public struct StagedAsset: Sendable, Equatable {
    public let relativePath: String
    public let absoluteURL: URL
    public let sha256: String
    public let byteCount: Int
}

/// Staging Directory Manager: atomic write + SHA256 deduplication.
public actor StagingStore {
    public nonisolated let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func makeDefault() throws -> StagingStore {
        try StagingStore(root: NovPoolPaths.stagingRoot())
    }

    /// Temporarily store memory byte stream (P1 WebImage follows this path).
    @discardableResult
    public func stage(data: Data, preferredExtension: String) throws -> StagedAsset {
        let directoryName = UUID().uuidString
        let directory = root.appending(path: directoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "asset.\(normalizedExtension(preferredExtension))"
        let destination = directory.appending(path: fileName)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw NovPoolError.stagingFailure(String(describing: error))
        }

        return StagedAsset(
            relativePath: "\(directoryName)/\(fileName)",
            absoluteURL: destination,
            sha256: Self.sha256Hex(of: data),
            byteCount: data.count
        )
    }

    /// Temporary disk File (P0 local File follows this path). First copy to a temporary name and then atomically rename it to avoid incomplete Files being indexed.
    @discardableResult
    public func stage(fileURL: URL) throws -> StagedAsset {
        let directoryName = UUID().uuidString
        let directory = root.appending(path: directoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = fileURL.lastPathComponent.isEmpty ? "asset" : fileURL.lastPathComponent
        let destination = directory.appending(path: fileName)
        let temporary = directory.appending(path: ".\(fileName).partial")

        do {
            if fileManager.fileExists(atPath: temporary.path(percentEncoded: false)) {
                try fileManager.removeItem(at: temporary)
            }
            try fileManager.copyItem(at: fileURL, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            throw NovPoolError.stagingFailure(String(describing: error))
        }

        let digest = try Self.sha256Hex(ofFileAt: destination)
        let attributes = try? fileManager.attributesOfItem(atPath: destination.path(percentEncoded: false))
        let size = (attributes?[.size] as? Int) ?? 0
        return StagedAsset(
            relativePath: "\(directoryName)/\(fileName)",
            absoluteURL: destination,
            sha256: digest,
            byteCount: size
        )
    }

    public func absoluteURL(forRelativePath relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    public func remove(relativePath: String) throws {
        let directory = root.appending(path: relativePath).deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try fileManager.removeItem(at: directory)
        }
    }

    // MARK: - Hash

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stream hashing, to avoid loading the entire large file into memory.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw NovPoolError.stagingFailure("Could not read file: \(url.path(percentEncoded: false))")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedExtension(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !trimmed.isEmpty else { return "dat" }
        return trimmed.lowercased()
    }
}
