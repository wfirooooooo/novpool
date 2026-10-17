import Foundation
import NovPoolCore
import Testing
@testable import NovPoolConnectors

@Suite("本地云盘挂载连接器")
struct ConnectorTests {
    private func connectorConfig(root: URL, template: String = NamingTemplate.defaultTemplate) throws -> Data {
        try JSONEncoder().encode(LocalCloudMountConnector.Config(
            namingTemplate: template,
            rootPath: root.path(percentEncoded: false)
        ))
    }

    @Test("按命名模板创建目录树并写入原始文件")
    func writesFileIntoDirectoryTree() async throws {
        let root = try TestSupport.makeTemporaryDirectory("gdrive")
        let stagingDirectory = try TestSupport.makeTemporaryDirectory("staging")
        let staged = stagingDirectory.appending(path: "报告.pdf")
        try Data("%PDF-fake".utf8).write(to: staged)

        let connector = LocalCloudMountConnector()
        var payload = TestSupport.samplePayload(title: "多云知识路由/白皮书", contentType: .documentPDF, category: "技术")
        payload.localStagedURL = staged

        let config = try connectorConfig(root: root)
        #expect(try await connector.validateAuthentication(configJSON: config))

        let receipt = try await connector.push(payload: payload, configJSON: config)
        #expect(receipt.remoteItemID.contains("技术/"))
        #expect(receipt.remoteItemID.hasSuffix(".pdf"))
        #expect(FileManager.default.fileExists(atPath: receipt.remoteWebURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: receipt.remoteWebURL) == Data("%PDF-fake".utf8))
    }

    @Test("无原始文件时落一份带 Front Matter 的 Markdown")
    func writesMarkdownFallback() async throws {
        let root = try TestSupport.makeTemporaryDirectory("obsidian")
        let connector = LocalCloudMountConnector()
        var payload = TestSupport.samplePayload(title: "剪藏笔记", contentType: .richHTML, body: "# 正文", category: "阅读")
        payload.aiSummary = "一段摘要"
        payload.aiTags = ["剪藏", "阅读"]

        let receipt = try await connector.push(
            payload: payload,
            configJSON: try connectorConfig(root: root)
        )
        let markdown = try String(contentsOf: receipt.remoteWebURL, encoding: .utf8)
        #expect(receipt.remoteWebURL.pathExtension == "md")
        #expect(markdown.contains("title: 剪藏笔记"))
        #expect(markdown.contains("source: https://example.com/a"))
        #expect(markdown.contains("tags: [剪藏, 阅读]"))
        #expect(markdown.contains("> 一段摘要"))
        #expect(markdown.contains("# 正文"))
    }

    @Test("未配置目标目录时鉴权校验失败而非抛错")
    func unconfiguredRoot() async throws {
        let connector = LocalCloudMountConnector()
        let empty = try JSONEncoder().encode(LocalCloudMountConnector.Config())
        #expect(try await connector.validateAuthentication(configJSON: empty) == false)
        await #expect(throws: NovPoolError.self) {
            try await connector.push(payload: TestSupport.samplePayload(), configJSON: empty)
        }
    }

    @Test("模板渲染：占位符替换、扩展名补齐、路径穿越清洗")
    func templateRendering() {
        let template = NamingTemplate(template: "{Category}/{YYYY}-{MM}/{Title}.{ext}")
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 9
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
        let date = calendar.date(from: components)!

        let payload = TestSupport.samplePayload(
            title: "标题/含斜杠:与冒号",
            contentType: .image,
            category: "技术"
        )

        let path = template.render(payload: payload, fileExtension: "png", date: date, calendar: calendar)
        #expect(path == "技术/2026-03/标题-含斜杠-与冒号.png")

        let escaping = NamingTemplate(template: "../../{Title}.{ext}")
            .render(payload: TestSupport.samplePayload(title: "x"), fileExtension: "md", date: date, calendar: calendar)
        #expect(!escaping.contains(".."))

        let withoutExtension = NamingTemplate(template: "{Title}")
            .render(payload: TestSupport.samplePayload(title: "无扩展名"), fileExtension: "md", date: date, calendar: calendar)
        #expect(withoutExtension.hasSuffix(".md"))
    }
}
