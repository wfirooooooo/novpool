import Foundation

/// 从 DOCX（OOXML Zip）提取纯文本，不引入第三方库。
///
/// 实现：调用系统 `unzip -p` 读出 `word/document.xml`，再用 `XMLDocument` 收集 `w:t`。
enum DOCXTextExtractor {
    static let maximumCharacters = LocalFileContent.maximumCharacters

    /// 从已解出的 `word/document.xml` 文本提取段落。
    static func plainText(fromDocumentXML xml: String) -> String? {
        guard let data = xml.data(using: .utf8) else { return nil }
        return plainText(fromDocumentXMLData: data)
    }

    static func plainText(fromDocumentXMLData data: Data) -> String? {
        guard let document = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]) else {
            return nil
        }
        // 按段落收集，段落内拼接 run 文本。
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
            joined = String(joined.prefix(maximumCharacters)) + "\n\n…（内容过长，已截断）"
        }
        return joined
    }

    /// 从 `.docx` 文件路径提取正文。
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
