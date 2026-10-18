import Foundation
import NovPoolCore
import Testing
@testable import NovPoolSystemBridge

@Suite("Silent tracing of browser context")
struct BrowserContextExtractorTests {
    @Test("Chromium-based browsers use active tab scripts")
    func chromiumScript() async throws {
        let runner = FakeScriptRunner(output: ["https://example.com/post", "Sample Article"])
        let extractor = BrowserContextExtractor(
            frontmostApp: FakeFrontmostApp(bundleID: "com.google.Chrome"),
            scripting: runner,
            axReader: nil
        )

        let context = await extractor.captureContext()
        #expect(context.pageURL?.absoluteString == "https://example.com/post")
        #expect(context.pageTitle == "Sample Article")
        #expect(context.appBundleID == "com.google.Chrome")
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts[0].contains("active tab of front window"))
    }

    @Test("Safari uses current tab / name script")
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

    @Test("Firefox takes the AXUIElement downgrade path")
    func firefoxUsesAccessibility() async throws {
        let runner = FakeScriptRunner(output: ["https://should-not-be-used.example"])
        let extractor = BrowserContextExtractor(
            frontmostApp: FakeFrontmostApp(bundleID: "org.mozilla.firefox"),
            scripting: runner,
            axReader: FakeAXReader(snapshot: AXBrowserSnapshot(
                url: URL(string: "https://news.example.com/tech"),
                title: "Technology News"
            ))
        )

        let context = await extractor.captureContext()
        #expect(context.pageURL?.absoluteString == "https://news.example.com/tech")
        #expect(context.pageTitle == "Technology News")
        #expect(runner.scripts.isEmpty)
    }

    @Test("Non-browser applications only record the source Bundle ID and do not execute scripts")
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

    @Test("Scripts that fail / timeout / return illegal values will all be silently degraded")
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

    @Test("The real AppleScript executor returns nil within the timeout budget without blocking")
    func realRunnerHonorsTimeout() async throws {
        let runner = NSAppleScriptRunner()
        let start = ContinuousClock.now
        // Inside the script, first delay: regardless of whether the system allows AppleEvents,
        // The caller must get nil within a 150ms budget, rather than waiting for the script to finish running.
        let output = await runner.run("delay 5\nreturn {1}", timeout: .milliseconds(150))
        #expect(output == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("Strict verification of URL and title normalization")
    func normalization() {
        #expect(BrowserContextExtractor.normalizeURL("  https://a.com/x  ")?.absoluteString == "https://a.com/x")
        #expect(BrowserContextExtractor.normalizeURL("about:blank") == nil)
        #expect(BrowserContextExtractor.normalizeURL("javascript:alert(1)") == nil)
        #expect(BrowserContextExtractor.normalizeURL("https://a.com/b c") == nil)
        #expect(BrowserContextExtractor.normalizeURL("") == nil)
        // When a browser tab points to a local HTML file, it must also be accepted (otherwise the entire tag will be silently discarded)
        #expect(BrowserContextExtractor.normalizeURL("file:///tmp/novpool-fixtures/manual.html")?.isFileURL == true)
        #expect(BrowserContextExtractor.normalizeTitle("  ") == nil)
        #expect(BrowserContextExtractor.normalizeTitle("Title") == "Title")
    }

    @Test("Browser family determination covers mainstream Bundle IDs")
    func familyMapping() {
        #expect(BrowserFamily.family(forBundleID: "com.google.Chrome") == .chromium)
        #expect(BrowserFamily.family(forBundleID: "company.thebrowser.Browser") == .chromium)
        #expect(BrowserFamily.family(forBundleID: "com.apple.Safari") == .safari)
        #expect(BrowserFamily.family(forBundleID: "org.mozilla.firefox") == .accessibility)
        #expect(BrowserFamily.family(forBundleID: "com.apple.finder") == nil)
    }
}

/// AX read stand-in.
struct FakeAXReader: AXBrowserReading {
    var snapshot: AXBrowserSnapshot?

    func readAddressBar(processIdentifier: pid_t) async -> AXBrowserSnapshot? {
        snapshot
    }
}
