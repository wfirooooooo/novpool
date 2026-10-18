import Foundation

/// Extract plain text from DOCX (OOXML Zip) without introducing third-party libraries.
///
/// Implementation: Call the system `unzip -p` to read `word/document.xml`, then use `XMLDocument` to collect `w:t`.
enum DOCXTextExtractor {
    static let maximumCharacters = LocalFileContent.maximumCharacters

    /// Extract paragraphs from the text of the already parsed `word/document.xml`.
    static func plainText(fromDocumentXML xml: String) -> String? {
        guard let data = xml.data(using: .utf8) else { return nil }
        return plainText(fromDocumentXMLData: data)
    }

    static func plainText(fromDocumentXMLData data: Data) -> String? {
        guard let document = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]) else {
            return nil
        }
        // Collect by paragraph, and concatenate run Text within the paragraph.
        let paragraphs = (try? document.nodes(forXPath: "//*[local-name()='p']")) ?? []
        var lines: [String] = []
        for paragraph in paragraphs {
            guard let element = paragraph as? XMLElement else { continue }
            let runs = (try? element.nodes(forXPath: ".//*[local-name()='t']")) ?? []
            let text = runs.compactMap { $0.stringValue }.joined()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(trimmed)
            }
        }
        guard !lines.isEmpty else { return nil }
        var joined = lines.joined(separator: "\n\n")
        if joined.count > maximumCharacters {
            joined = String(joined.prefix(maximumCharacters)) + "\n\n… (truncated; content too long)"
        }
        return joined
    }

    /// Extract the Body from a `.docx` file path.
    static func extract(from url: URL) -> String? {
        guard url.pathExtension.lowercased() == "docx" else { return nil }
        guard let xmlData = unzippedDocumentXML(from: url) else { return nil }
        return plainText(fromDocumentXMLData: xmlData)
    }

    private static func unzippedDocumentXML(from url: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path(percentEncoded: false), "word/document.xml"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }
}
