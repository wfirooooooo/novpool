import Foundation
import Testing
@testable import NovPoolCore
@testable import NovPoolStorage

@Suite("Staging 原子写入与哈希去重")
struct StagingStoreTests {
    // MARK: - 首次启动的目录创建（回归用例）

    @Test("数据目录不存在时能被创建（首次启动必崩的回归用例）")
    func ensureDirectoryCreatesMissingPath() throws {
        let base = try TestSupport.makeTemporaryDirectory("paths")
        let nested = base.appending(path: "NovPool/Staging", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: nested.path(percentEncoded: false)))

        try NovPoolPaths.ensureDirectory(at: nested)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: nested.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        // 幂等：已存在时不应抛错
        try NovPoolPaths.ensureDirectory(at: nested)
    }

    @Test("父目录不存在时也能建库（SQLite 不会自己建目录）")
    func databaseCreatesParentDirectory() async throws {
        let base = try TestSupport.makeTemporaryDirectory("dbparent")
        let databaseFile = base.appending(path: "NovPool/novpool.sqlite")
        #expect(!FileManager.default.fileExists(atPath: databaseFile.deletingLastPathComponent().path(percentEncoded: false)))

        let database = try NovPoolDatabase(path: databaseFile.path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        #expect(try await KnowledgeRepository(database: database).count() == 0)
        #expect(FileManager.default.fileExists(atPath: databaseFile.path(percentEncoded: false)))
    }

    @Test("内存字节流暂存后哈希稳定且可读回")
    func stageData() async throws {
        let root = try TestSupport.makeTemporaryDirectory("staging")
        let store = try StagingStore(root: root)
        let bytes = Data("图片二进制内容".utf8)

        let asset = try await store.stage(data: bytes, preferredExtension: ".PNG")
        #expect(asset.relativePath.hasSuffix("/asset.png"))
        #expect(asset.byteCount == bytes.count)
        #expect(asset.sha256 == StagingStore.sha256Hex(of: bytes))
        #expect(try Data(contentsOf: asset.absoluteURL) == bytes)

        // 相同内容 → 相同哈希，用于去重判定。
        let second = try await store.stage(data: bytes, preferredExtension: "png")
        #expect(second.sha256 == asset.sha256)
        #expect(second.relativePath != asset.relativePath)
    }

    @Test("磁盘文件按原文件名暂存，且流式哈希与整体哈希一致")
    func stageFile() async throws {
        let root = try TestSupport.makeTemporaryDirectory("staging-file")
        let store = try StagingStore(root: root)
        let sourceDirectory = try TestSupport.makeTemporaryDirectory("source")
        let source = sourceDirectory.appending(path: "季度报告.pdf")
        let payload = Data(repeating: 0x41, count: 4096)
        try payload.write(to: source)

        let asset = try await store.stage(fileURL: source)
        #expect(asset.relativePath.hasSuffix("/季度报告.pdf"))
        #expect(asset.sha256 == StagingStore.sha256Hex(of: payload))
        #expect(asset.byteCount == 4096)
        // 原文件保持不动（是复制而非移动）。
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test("暂存目录内不残留 .partial 临时文件")
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
