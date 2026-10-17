import Foundation
import NovPoolCore
import Testing
@testable import NovPoolSystemBridge

@Suite("浏览器上下文静默溯源")
struct BrowserContextExtractorTests {
    @Test("Chromium 系浏览器使用 active tab 脚本")
    func chromiumScript() async throws {
        let runner = FakeScriptRunner(output: ["https://example.com/post", "示例文章"])
        let extractor = BrowserContextExtractor(
            frontmostApp: FakeFrontmostApp(bundleID: "com.google.Chrome"),
            scripting: runner,
            axReader: nil
        )

        let context = await extractor.captureContext()
        #expect(context.pageURL?.absoluteString == "https://example.com/post")
        #expect(context.pageTitle == "示例文章")
        #expect(context.appBundleID == "com.google.Chrome")
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts[0].contains("active tab of front window"))
    }

    @Test("Safari 使用 current tab / name 脚本")
    func safariScript() async throws {
        let runner = FakeScriptRunner(output: ["https://apple.com", "Apple"])
        let extractor = BrowserContextExtractor(
            frontmostApp: FakeFrontmostApp(bundleID: "com.apple.Safari"),
            scripting: runner,
            axReader: nil
        )

        let context = await extractor.captureContext()
        #expect(context.pageURL?.absoluteString == "https://apple.com")
        #expect(runner.scripts[0].contains("current tab of front window"))
        #expect(runner.scripts[0].contains("com.apple.Safari"))
    }

    @Test("Firefox 走 AXUIElement 降级路径")
    func firefoxUsesAccessibility() async throws {
        let runner = FakeScriptRunner(output: ["https://should-not-be-used.example"])
        let extractor = BrowserContextExtractor(
            frontmostApp: FakeFrontmostApp(bundleID: "org.mozilla.firefox"),
            scripting: runner,
            axReader: FakeAXReader(snapshot: AXBrowserSnapshot(
                url: URL(string: "https://news.example.com/tech"),
                title: "科技新闻"
            ))
        )

        let context = await extractor.captureContext()
        #expect(context.pageURL?.absoluteString == "https://news.example.com/tech")
        #expect(context.pageTitle == "科技新闻")
        #expect(runner.scripts.isEmpty)
    }

    @Test("非浏览器应用只记录来源 Bundle ID，不执行脚本")
    func nonBrowserApp() async throws {
        let runner = FakeScriptRunner(output: ["https://example.com"])
        let extractor = BrowserContextExtractor(
            frontmostApp: FakeFrontmostApp(bundleID: "com.apple.finder"),
            scripting: runner,
            axReader: nil
        )

        let context = await extractor.captureContext()
        #expect(context.appBundleID == "com.apple.finder")
        #expect(context.pageURL == nil)
        #expect(runner.scripts.isEmpty)
    }

    @Test("脚本失败 / 超时 / 非法返回值一律静默降级")
    func silentDegradation() async throws {
        let failing = BrowserContextExtractor(
            frontmostApp: FakeFrontmostApp(bundleID: "com.google.Chrome"),
            scripting: FakeScriptRunner(output: nil),
            axReader: nil
        )
        #expect(await failing.captureContext().pageURL == nil)

        let garbage = BrowserContextExtractor(
            frontmostApp: FakeFrontmostApp(bundleID: "com.google.Chrome"),
            scripting: FakeScriptRunner(output: ["about:blank", ""]),
            axReader: nil
        )
        #expect(await garbage.captureContext().pageURL == nil)
    }

    @Test("真实 AppleScript 执行器在超时预算内返回 nil 而不阻塞")
    func realRunnerHonorsTimeout() async throws {
        let runner = NSAppleScriptRunner()
        let start = ContinuousClock.now
        // 脚本内部先 delay：无论系统是否允许 AppleEvents，
        // 调用方都必须在 150ms 预算内拿到 nil，而不是等脚本跑完。
        let output = await runner.run("delay 5\nreturn {1}", timeout: .milliseconds(150))
        #expect(output == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("URL 与标题归一化严格校验")
    func normalization() {
        #expect(BrowserContextExtractor.normalizeURL("  https://a.com/x  ")?.absoluteString == "https://a.com/x")
        #expect(BrowserContextExtractor.normalizeURL("about:blank") == nil)
        #expect(BrowserContextExtractor.normalizeURL("javascript:alert(1)") == nil)
        #expect(BrowserContextExtractor.normalizeURL("https://a.com/b c") == nil)
        #expect(BrowserContextExtractor.normalizeURL("") == nil)
        // 浏览器标签指向本机 HTML 文件时同样要接受（否则整条标签会被静默丢弃）
        #expect(BrowserContextExtractor.normalizeURL("file:///Users/wong/manual.html")?.isFileURL == true)
        #expect(BrowserContextExtractor.normalizeTitle("  ") == nil)
        #expect(BrowserContextExtractor.normalizeTitle("标题") == "标题")
    }

    @Test("浏览器家族判定覆盖主流 Bundle ID")
    func familyMapping() {
        #expect(BrowserFamily.family(forBundleID: "com.google.Chrome") == .chromium)
        #expect(BrowserFamily.family(forBundleID: "company.thebrowser.Browser") == .chromium)
        #expect(BrowserFamily.family(forBundleID: "com.apple.Safari") == .safari)
        #expect(BrowserFamily.family(forBundleID: "org.mozilla.firefox") == .accessibility)
        #expect(BrowserFamily.family(forBundleID: "com.apple.finder") == nil)
    }
}

/// AX 读取替身。
struct FakeAXReader: AXBrowserReading {
    var snapshot: AXBrowserSnapshot?

    func readAddressBar(processIdentifier: pid_t) async -> AXBrowserSnapshot? {
        snapshot
    }
}
