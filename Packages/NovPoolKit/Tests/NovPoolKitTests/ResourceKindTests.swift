import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolUI
@testable import NovPoolSystemBridge

@Suite("拖拽资源类型判断")
struct ResourceKindTests {
    private let resolver = PasteboardResolver()

    @Test("扩展名分类：图片 / 视频 / PDF / 普通文件")
    func fileKindClassification() {
        for ext in ["png", "JPG", "heic", "webp"] {
            #expect(FileKind.of(pathExtension: ext) == .image)
        }
        for ext in ["mp4", "MOV", "mkv", "webm"] {
            #expect(FileKind.of(pathExtension: ext) == .video)
        }
        #expect(FileKind.of(pathExtension: "pdf") == .pdf)
        #expect(FileKind.of(pathExtension: "docx") == .other)
        #expect(FileKind.of(pathExtension: "") == .other)

        #expect(FileKind.image.contentType == .image)
        #expect(FileKind.video.contentType == .video)
        #expect(FileKind.pdf.contentType == .documentPDF)
        #expect(FileKind.other.contentType == .genericFile)
    }

    @Test("拖入图片文件：判为图片，但仍携带本地文件路径")
    func imageFile() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, "file:///tmp/%E7%A4%BA%E6%84%8F%E5%9B%BE.png"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .image)
        #expect(content.fileURLs.count == 1)
        #expect(content.imageData == nil)   // 图片文件走文件暂存，不走内存字节
    }

    @Test("拖入视频文件：判为视频")
    func videoFile() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, "file:///tmp/%E6%BC%94%E7%A4%BA.mov"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .video)
        #expect(content.fileURLs.first?.pathExtension == "mov")
    }

    @Test("拖入 PDF 与办公文档：分别判为 PDF 与普通文件")
    func documentFiles() throws {
        let pdf = try #require(resolver.resolve(from: FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, "file:///tmp/report.pdf"),
        ])))
        #expect(pdf.contentType == .documentPDF)

        let docx = try #require(resolver.resolve(from: FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, "file:///tmp/notes.docx"),
        ])))
        #expect(docx.contentType == .genericFile)
    }

    @Test("网页内联视频字节：判为视频并记录媒体类型")
    func inlineVideoData() throws {
        let pasteboard = FakePasteboard([
            (PasteboardTypeID.mpeg4Movie, Data(repeating: 0x00, count: 64)),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .video)
        #expect(content.imageTypeIdentifier == PasteboardTypeID.mpeg4Movie)
        #expect(content.imageData?.count == 64)
    }

    @MainActor
    @Test("拖拽接收视图注册了图片、视频与浏览器标签的粘贴板类型")
    func dragViewAcceptsEveryResourceType() {
        let types = Set(DragReceivingView.supportedTypes.map(\.rawValue))
        #expect(types.isSuperset(of: [
            PasteboardTypeID.fileURL,
            PasteboardTypeID.png,
            PasteboardTypeID.tiff,
            PasteboardTypeID.mpeg4Movie,
            PasteboardTypeID.movie,
            PasteboardTypeID.quickTimeMovie,
            PasteboardTypeID.url,
            PasteboardTypeID.urlName,
            PasteboardTypeID.uriList,
            PasteboardTypeID.mozURL,
        ]))
    }

    @Test("图片、视频与普通文件都从粘贴板解析后落库并暂存原件")
    func ingestionStagesAllKinds() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("kinds")
        let database = try NovPoolDatabase(path: directory.appending(path: "db.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        let staging = try StagingStore(root: directory.appending(path: "Staging", directoryHint: .isDirectory))
        let orchestrator = IngestionOrchestrator(
            database: database,
            staging: staging,
            browserContext: FakeBrowserContext(context: SourceContext(appBundleID: "com.apple.finder"))
        )

        for (index, (name, expected)) in [
            ("chart.png", ContentType.image),
            ("clip.mp4", ContentType.video),
            ("notes.md", ContentType.genericFile),
        ].enumerated() {
            let source = directory.appending(path: name)
            // 内容哈希不同，避免第二条被当成第一条的跨类型重复项。
            try Data(repeating: UInt8(0x41 + index), count: 256).write(to: source)
            let content = try #require(resolver.resolve(from: FakePasteboard(strings: [
                (PasteboardTypeID.fileURL, source.absoluteString),
            ])))
            let result = try await orchestrator.ingest(
                content
            )
            #expect(content.contentType == expected)
            #expect(result.record.contentType == expected)
            #expect(result.record.localRelativePath?.hasSuffix(name) == true)
            #expect(result.record.fileHashSHA256?.count == 64)
        }
    }
}
