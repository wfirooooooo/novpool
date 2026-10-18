import Foundation
import NovPoolCore
import NovPoolSystemBridge
import AppKit
import CoreGraphics
import CoreText

/// Memory clipboard proxy.
///
/// The real `NSPasteboard` requires WindowServer and the `pboard` daemon in an environment without a GUI session
/// Completely unusable (`data(forType:)` is always `nil`), so the parsing logic is tested exclusively against abstract protocols.
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

/// Front-end application stand-in.
struct FakeFrontmostApp: FrontmostAppProviding {
    var bundleID: String?
    var processIdentifier: pid_t = 4242

    func frontmostApplication() -> (bundleID: String, processIdentifier: pid_t)? {
        bundleID.map { ($0, processIdentifier) }
    }
}

/// AppleScript executor proxy, records the source code of the scripts that have been called.
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

    /// Synchronous locking helper: `NSLock.lock()` is marked as unavailable in async contexts in Swift.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Traceability provider substitute.
struct FakeBrowserContext: BrowserContextProviding {
    var context: SourceContext

    func captureContext() async -> SourceContext { context }
}

/// HTTP transport stub: can orchestrate responses or inject Errors.
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

/// Text recognition stand-in.
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

/// Web scraping substitute.
struct FakeFetcher: ArticleFetching {
    var result: WebFetchResult

    func fetchArticle(from url: URL) async -> WebFetchResult { result }
}

/// AI-enhanced substitute.
struct FakeAI: AIEnriching {
    var enrichment: AIEnrichment?
    var shouldFail = false
    var failureReason = "The stunt double intentionally failed"

    func enrichDetailed(_ request: AIEnrichmentRequest) async -> AIEnrichmentOutcome {
        if shouldFail { return .failure(failureReason) }
        if let enrichment { return .success(enrichment) }
        return .failure("The substitute has not configured enhancement results")
    }
}

enum TestSupport {
    /// Create a disposable sandbox directory.
    static func makeTemporaryDirectory(_ label: String = "novpool") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func samplePayload(
        title: String = "Example Document",
        contentType: ContentType = .plainText,
        body: String? = "Body",
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
                pageTitle: "Example Page Title"
            )
        )
    }

    /// Use CoreText to draw a bitmap containing text (for reuse in OCR-related testing).
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

    /// Generate a PDF with a text layer (used to verify 'text layer takes precedence over OCR').
    ///
    /// Text is wrapped and drawn at a fixed length: if a single line is too wide, it will be cut off by the page, and the text layer will become shorter accordingly.
    /// Such a sample cannot represent a real document.
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
