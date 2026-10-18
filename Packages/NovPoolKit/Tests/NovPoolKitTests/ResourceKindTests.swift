import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolUI
@testable import NovPoolSystemBridge

@Suite("Drag-and-drop resource type determination")
struct ResourceKindTests {
    private let resolver = PasteboardResolver()

    @Test("File Extension Classification: Image / Video / PDF / Regular File")
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

    @Test("Dragged into ImageFile: recognized as Image, but still carries the local File path")
    func imageFile() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, "file:///tmp/%E7%A4%BA%E6%84%8F%E5%9B%BE.png"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .image)
        #expect(content.fileURLs.count == 1)
        #expect(content.imageData == nil)   // ImageFile goes through file temporary storage, not through memory bytes
    }

    @Test("Drag into VideoFile: classified as Video")
    func videoFile() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, "file:///tmp/%E6%BC%94%E7%A4%BA.mov"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .video)
        #expect(content.fileURLs.first?.pathExtension == "mov")
    }

    @Test("Drag into PDF and Office Document: classify as PDF and regular File respectively")
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

    @Test("Web inline Video bytes: judged as Video and record media type")
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
    @Test("The drag-and-drop receiving view has registered clipboard types for Image, Video, and Browser tab")
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

    @Test("Images, videos, and regular files are all parsed from the clipboard, stored in the database, and temporarily save the originals.")
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
            // The content hash is different, preventing the second item from being treated as a cross-type duplicate of the first.
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
