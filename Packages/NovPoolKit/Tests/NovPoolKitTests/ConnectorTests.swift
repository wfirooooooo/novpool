import Foundation
import NovPoolCore
import Testing
@testable import NovPoolConnectors

@Suite("Local Cloud Drive Mount Connector")
struct ConnectorTests {
    private func connectorConfig(root: URL, template: String = NamingTemplate.defaultTemplate) throws -> Data {
        try JSONEncoder().encode(LocalCloudMountConnector.Config(
            namingTemplate: template,
            rootPath: root.path(percentEncoded: false)
        ))
    }

    @Test("Create a directory tree according to the naming template and write the original file")
    func writesFileIntoDirectoryTree() async throws {
        let root = try TestSupport.makeTemporaryDirectory("gdrive")
        let stagingDirectory = try TestSupport.makeTemporaryDirectory("staging")
        let staged = stagingDirectory.appending(path: "Report.pdf")
        try Data("%PDF-fake".utf8).write(to: staged)

        let connector = LocalCloudMountConnector()
        var payload = TestSupport.samplePayload(title: "Cloud Knowledge Routing / White Paper", contentType: .documentPDF, category: "Technology")
        payload.localStagedURL = staged

        let config = try connectorConfig(root: root)
        #expect(try await connector.validateAuthentication(configJSON: config))

        let receipt = try await connector.push(payload: payload, configJSON: config)
        #expect(receipt.remoteItemID.contains("Technology/"))
        #expect(receipt.remoteItemID.hasSuffix(".pdf"))
        #expect(FileManager.default.fileExists(atPath: receipt.remoteWebURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: receipt.remoteWebURL) == Data("%PDF-fake".utf8))
    }

    @Test("When there is no original file, create a copy of the Markdown with Front Matter")
    func writesMarkdownFallback() async throws {
        let root = try TestSupport.makeTemporaryDirectory("obsidian")
        let connector = LocalCloudMountConnector()
        var payload = TestSupport.samplePayload(title: "Clipping Notes", contentType: .richHTML, body: "# Body", category: "Reading")
        payload.aiSummary = "A summary"
        payload.aiTags = ["Clip and save", "Reading"]

        let receipt = try await connector.push(
            payload: payload,
            configJSON: try connectorConfig(root: root)
        )
        let markdown = try String(contentsOf: receipt.remoteWebURL, encoding: .utf8)
        #expect(receipt.remoteWebURL.pathExtension == "md")
        #expect(markdown.contains("title: Clipping Notes"))
        #expect(markdown.contains("source: https://example.com/a"))
        #expect(markdown.contains("tags: [Clip and save, Reading]"))
        #expect(markdown.contains("> A summary"))
        #expect(markdown.contains("# Body"))
    }

    @Test("Authentication check fails instead of throwing an error when the target directory is not configured")
    func unconfiguredRoot() async throws {
        let connector = LocalCloudMountConnector()
        let empty = try JSONEncoder().encode(LocalCloudMountConnector.Config())
        #expect(try await connector.validateAuthentication(configJSON: empty) == false)
        await #expect(throws: NovPoolError.self) {
            try await connector.push(payload: TestSupport.samplePayload(), configJSON: empty)
        }
    }

    @Test("Template rendering: placeholder replacement, extension completion, path traversal sanitization")
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
            title: "Title/With-Slash:And-Colon",
            contentType: .image,
            category: "Technology"
        )

        let path = template.render(payload: payload, fileExtension: "png", date: date, calendar: calendar)
        #expect(path == "Technology/2026-03/Title-With-Slash-And-Colon.png")

        let escaping = NamingTemplate(template: "../../{Title}.{ext}")
            .render(payload: TestSupport.samplePayload(title: "x"), fileExtension: "md", date: date, calendar: calendar)
        #expect(!escaping.contains(".."))

        let withoutExtension = NamingTemplate(template: "{Title}")
            .render(payload: TestSupport.samplePayload(title: "No extension"), fileExtension: "md", date: date, calendar: calendar)
        #expect(withoutExtension.hasSuffix(".md"))
    }
}
