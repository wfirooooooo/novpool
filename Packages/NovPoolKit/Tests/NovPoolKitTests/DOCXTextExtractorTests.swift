import Foundation
import Testing
@testable import NovPoolSystemBridge

@Suite("DOCX Body Extraction")
struct DOCXTextExtractorTests {
    @Test("Extract w:t from document.xml by paragraph")
    func parsesDocumentXML() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>First paragraph</w:t></w:r></w:p>
            <w:p><w:r><w:t>Hello </w:t></w:r><w:r><w:t>World</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let text = DOCXTextExtractor.plainText(fromDocumentXML: xml)
        #expect(text == "First paragraph\n\nHello World")
    }

    @Test("The real docx zip can have the Body extracted")
    func extractsFromDOCXFile() throws {
        let dir = try TestSupport.makeTemporaryDirectory("docx")
        defer { try? FileManager.default.removeItem(at: dir) }

        let docx = try makeMinimalDOCX(
            in: dir,
            paragraphs: ["Cloud Knowledge Routing", "Phase C DOCX Extract"]
        )
        let text = try #require(DOCXTextExtractor.extract(from: docx))
        #expect(text.contains("Cloud Knowledge Routing"))
        #expect(text.contains("Phase C DOCX Extract"))

        let extracted = try #require(LocalFileContent.extract(from: docx))
        #expect(extracted.markdown.contains("Cloud Knowledge Routing"))
    }

    private func makeMinimalDOCX(in directory: URL, paragraphs: [String]) throws -> URL {
        let root = directory.appending(path: "pkg", directoryHint: .isDirectory)
        let word = root.appending(path: "word", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: word, withIntermediateDirectories: true)

        let body = paragraphs.map { "<w:p><w:r><w:t>\($0)</w:t></w:r></w:p>" }.joined()
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>\(body)</w:body>
        </w:document>
        """
        try documentXML.write(to: word.appending(path: "document.xml"), atomically: true, encoding: .utf8)

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        try contentTypes.write(
            to: root.appending(path: "[Content_Types].xml"),
            atomically: true,
            encoding: .utf8
        )

        let docx = directory.appending(path: "sample.docx")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.arguments = ["-qr", docx.path(percentEncoded: false), "."]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return docx
    }
}
