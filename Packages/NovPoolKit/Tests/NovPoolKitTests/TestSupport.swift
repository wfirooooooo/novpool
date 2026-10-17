import Foundation
import NovPoolCore
import NovPoolSystemBridge
import AppKit
import CoreGraphics
import CoreText

/// 内存粘贴板替身。
///
/// 真实 `NSPasteboard` 需要 WindowServer 与 `pboard` 守护进程，在无 GUI 会话的环境中
/// 完全不可用（`data(forType:)` 恒为 `nil`），因此解析逻辑一律针对抽象协议测试。
struct FakePasteboard: PasteboardReading {
    var storage: [String: Data] = [:]
    var order: [String] = []

    init(_ entries: [(String, Data)] = []) {
        for (typeIdentifier, data) in entries {
            storage[typeIdentifier] = data
            order.append(typeIdentifier)
        }
    }

    init(strings entries: [(String, String)]) {
        self.init(entries.map { ($0.0, Data($0.1.utf8)) })
    }

    var availableTypeIdentifiers: [String] { order }

    func data(forTypeIdentifier typeIdentifier: String) -> Data? {
        storage[typeIdentifier]
    }

    func string(forTypeIdentifier typeIdentifier: String) -> String? {
        storage[typeIdentifier].map { String(decoding: $0, as: UTF8.self) }
    }
}

/// 前台应用替身。
struct FakeFrontmostApp: FrontmostAppProviding {
    var bundleID: String?
    var processIdentifier: pid_t = 4242

    func frontmostApplication() -> (bundleID: String, processIdentifier: pid_t)? {
        bundleID.map { ($0, processIdentifier) }
    }
}

/// AppleScript 执行器替身，记录调用过的脚本源码。
final class FakeScriptRunner: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var output: [String]?
    var delay: Duration = .zero

    init(output: [String]? = nil) {
        self.output = output
    }

    var scripts: [String] { withLock { recorded } }

    func run(_ source: String, timeout: Duration) async -> [String]? {
        withLock { recorded.append(source) }
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return output
    }

    /// 同步加锁助手：`NSLock.lock()` 在 async 上下文中被 Swift 标记为不可用。
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 溯源提供者替身。
struct FakeBrowserContext: BrowserContextProviding {
    var context: SourceContext

    func captureContext() async -> SourceContext { context }
}

/// HTTP 传输替身：可编排响应或注入错误。
final class StubTransport: HTTPTransport, @unchecked Sendable {
    enum StubError: Error { case offline }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var queue: [Result<HTTPPayload, Error>]

    init(responses: [HTTPPayload]) {
        self.queue = responses.map { .success($0) }
    }

    init(error: Error = StubError.offline) {
        self.queue = [.failure(error)]
    }

    var requests: [URLRequest] { withLock { recorded } }

    func send(_ request: URLRequest) async throws -> HTTPPayload {
        let next = withLock { queue.isEmpty ? nil : queue.removeFirst() }
        withLock { recorded.append(request) }
        guard let next else { throw StubError.offline }
        return try next.get()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 文本识别替身。
struct FakeOCR: ImageTextRecognizing {
    struct Failure: Error {}
    var imageText: String = "fake image text"
    var pdfText: String = "fake pdf text"
    var shouldFail = false

    func recognizeImageText(data: Data) async throws -> TextRecognitionResult {
        if shouldFail { throw Failure() }
        return TextRecognitionResult(
            text: imageText,
            blocks: [TextBlock(text: imageText, boundingBox: .init(x: 0, y: 0, width: 1, height: 1), confidence: 0.9)],
            origin: .visionOCR
        )
    }

    func recognizePDFText(at url: URL) async throws -> TextRecognitionResult {
        if shouldFail { throw Failure() }
        return TextRecognitionResult(
            text: pdfText,
            blocks: [TextBlock(text: pdfText, boundingBox: .init(x: 0, y: 0, width: 1, height: 1), confidence: 0.9)],
            origin: .visionOCR
        )
    }
}

/// 网页抓取替身。
struct FakeFetcher: ArticleFetching {
    var result: WebFetchResult

    func fetchArticle(from url: URL) async -> WebFetchResult { result }
}

/// AI 增强替身。
struct FakeAI: AIEnriching {
    var enrichment: AIEnrichment?
    var shouldFail = false

    func enrich(_ request: AIEnrichmentRequest) async -> AIEnrichment? {
        shouldFail ? nil : enrichment
    }
}

enum TestSupport {
    /// 创建一次性沙盒目录。
    static func makeTemporaryDirectory(_ label: String = "novpool") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func samplePayload(
        title: String = "示例文档",
        contentType: ContentType = .plainText,
        body: String? = "正文",
        category: String? = nil,
        tags: [String] = [],
        sourceApp: String = "com.google.Chrome",
        pageURL: URL? = URL(string: "https://example.com/a")
    ) -> NormalizedPayload {
        NormalizedPayload(
            contentType: contentType,
            title: title,
            markdownBody: body,
            aiCategory: category,
            aiTags: tags,
            sourceContext: SourceContext(
                appBundleID: sourceApp,
                pageURL: pageURL,
                pageTitle: "示例页面标题"
            )
        )
    }

    /// 用 CoreText 画一张含文字的位图（供 OCR 相关测试复用）。
    static func makeTextImage(_ text: String, fontSize: CGFloat = 64) -> CGImage? {
        let width = 1_000
        let height = 240
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: CGColor(gray: 0, alpha: 1),
            ]
        )
        context.textPosition = CGPoint(x: 40, y: CGFloat(height) / 3)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        return context.makeImage()
    }

    static func pngData(_ text: String, fontSize: CGFloat = 64) -> Data? {
        guard let image = makeTextImage(text, fontSize: fontSize) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// 生成一份带文字层的 PDF（用于验证「文字层优先于 OCR」）。
    ///
    /// 文本按固定长度折行绘制：单行超宽会被页面裁掉，文字层随之变短，
    /// 那样的样本无法代表真实文档。
    @discardableResult
    static func makePDF(text: String, at url: URL, pageCount: Int = 1) -> Bool {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return false
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let lineWidth = 36
        let lines = stride(from: 0, to: max(text.count, 1), by: lineWidth).map { offset -> String in
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: min(lineWidth, text.count - offset))
            return String(text[start..<end])
        }

        for page in 0..<max(1, pageCount) {
            context.beginPDFPage(nil)
            var y = 740.0
            for line in lines + ["p\(page + 1)"] {
                let attributed = NSAttributedString(
                    string: line,
                    attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
                )
                context.textPosition = CGPoint(x: 60, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                y -= 18
            }
            context.endPDFPage()
        }
        context.closePDF()
        return true
    }
}
