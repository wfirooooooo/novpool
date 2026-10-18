import Foundation
import Testing
@testable import NovPoolCore
@testable import NovPoolStorage

@Suite("Staging atomic write and hash deduplication")
struct StagingStoreTests {
    // MARK: - First-time startup directory creation (regression case)

    @Test("The data directory can be created if it does not exist (a regression case that always crashes on first startup)")
    func ensureDirectoryCreatesMissingPath() throws {
        let base = try TestSupport.makeTemporaryDirectory("paths")
        let nested = base.appending(path: "NovPool/Staging", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: nested.path(percentEncoded: false)))

        try NovPoolPaths.ensureDirectory(at: nested)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: nested.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        // Idempotent: should not throw an error if it already exists
        try NovPoolPaths.ensureDirectory(at: nested)
    }

    @Test("Can create the database even if the parent directory does not exist (SQLite will not create the directory by itself)")
    func databaseCreatesParentDirectory() async throws {
        let base = try TestSupport.makeTemporaryDirectory("dbparent")
        let databaseFile = base.appending(path: "NovPool/novpool.sqlite")
        #expect(!FileManager.default.fileExists(atPath: databaseFile.deletingLastPathComponent().path(percentEncoded: false)))

        let database = try NovPoolDatabase(path: databaseFile.path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        #expect(try await KnowledgeRepository(database: database).count() == 0)
        #expect(FileManager.default.fileExists(atPath: databaseFile.path(percentEncoded: false)))
    }

    @Test("After temporarily storing the memory byte stream, the hash is stable and can be read back")
    func stageData() async throws {
        let root = try TestSupport.makeTemporaryDirectory("staging")
        let store = try StagingStore(root: root)
        let bytes = Data("ImageBinary content".utf8)

        let asset = try await store.stage(data: bytes, preferredExtension: ".PNG")
        #expect(asset.relativePath.hasSuffix("/asset.png"))
        #expect(asset.byteCount == bytes.count)
        #expect(asset.sha256 == StagingStore.sha256Hex(of: bytes))
        #expect(try Data(contentsOf: asset.absoluteURL) == bytes)

        // Same content → same hash, used for deduplication determination.
        let second = try await store.stage(data: bytes, preferredExtension: "png")
        #expect(second.sha256 == asset.sha256)
        #expect(second.relativePath != asset.relativePath)
    }

    @Test("The disk file is temporarily saved under the original file name, and the stream hash is consistent with the overall hash.")
    func stageFile() async throws {
        let root = try TestSupport.makeTemporaryDirectory("staging-file")
        let store = try StagingStore(root: root)
        let sourceDirectory = try TestSupport.makeTemporaryDirectory("source")
        let source = sourceDirectory.appending(path: "Quarterly report.pdf")
        let payload = Data(repeating: 0x41, count: 4096)
        try payload.write(to: source)

        let asset = try await store.stage(fileURL: source)
        #expect(asset.relativePath.hasSuffix("/Quarterly report.pdf"))
        #expect(asset.sha256 == StagingStore.sha256Hex(of: payload))
        #expect(asset.byteCount == 4096)
        // The original file remains unchanged (it is a copy, not a move).
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test("No .partial temporary files remain in the temporary directory")
    func noPartialLeftovers() async throws {
        let root = try TestSupport.makeTemporaryDirectory("staging-clean")
        let store = try StagingStore(root: root)
        let sourceDirectory = try TestSupport.makeTemporaryDirectory("source-clean")
        let source = sourceDirectory.appending(path: "a.txt")
        try Data("hello".utf8).write(to: source)

        let asset = try await store.stage(fileURL: source)
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: asset.absoluteURL.deletingLastPathComponent().path(percentEncoded: false)
        )
        #expect(contents == ["a.txt"])

        try await store.remove(relativePath: asset.relativePath)
        #expect(!FileManager.default.fileExists(atPath: asset.absoluteURL.path(percentEncoded: false)))
    }
}
