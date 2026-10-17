import AppKit
import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolUI

@Suite("检索富预览分类")
struct SearchPreviewKindTests {
    @Test("无本地文件时不显示媒体区")
    func noLocalFile() {
        #expect(SearchPreviewKind.resolve(contentType: .image, localFileURL: nil) == .none)
        #expect(SearchPreviewKind.resolve(contentType: .documentPDF, localFileURL: nil) == .none)
    }

    @Test("按内容类型选择预览形态")
    func byContentType() {
        let png = URL(filePath: "/tmp/a.png")
        let pdf = URL(filePath: "/tmp/a.pdf")
        let mov = URL(filePath: "/tmp/a.mov")
        #expect(SearchPreviewKind.resolve(contentType: .image, localFileURL: png) == .image)
        #expect(SearchPreviewKind.resolve(contentType: .documentPDF, localFileURL: pdf) == .pdf)
        #expect(SearchPreviewKind.resolve(contentType: .video, localFileURL: mov) == .video)
    }

    @Test("genericFile 按扩展名回退到图 / PDF / 视频 / 缩略图")
    func genericFileByExtension() {
        #expect(
            SearchPreviewKind.resolve(
                contentType: .genericFile,
                localFileURL: URL(filePath: "/tmp/shot.heic")
            ) == .image
        )
        #expect(
            SearchPreviewKind.resolve(
                contentType: .genericFile,
                localFileURL: URL(filePath: "/tmp/doc.pdf")
            ) == .pdf
        )
        #expect(
            SearchPreviewKind.resolve(
                contentType: .genericFile,
                localFileURL: URL(filePath: "/tmp/clip.mp4")
            ) == .video
        )
        #expect(
            SearchPreviewKind.resolve(
                contentType: .genericFile,
                localFileURL: URL(filePath: "/tmp/notes.docx")
            ) == .fileThumbnail
        )
    }

    @Test("本机 PNG 可解码为 NSImage")
    func loadsLocalPNG() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "novpool-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "dot.png")
        // 1×1 透明 PNG
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let data = try #require(Data(base64Encoded: pngBase64))
        try data.write(to: url)

        let image = LocalPreviewLoader.image(at: url)
        #expect(image != nil)
        #expect(image?.size.width == 1)
    }
}
