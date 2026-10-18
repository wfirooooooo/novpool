import AppKit
import ApplicationServices
import Foundation
import NovPoolCore

/// Front-end application information provider (real implementation reads `NSWorkspace`).
public protocol FrontmostAppProviding: Sendable {
    func frontmostApplication() -> (bundleID: String, processIdentifier: pid_t)?
}

public struct WorkspaceFrontmostApp: FrontmostAppProviding {
    public init() {}

    public func frontmostApplication() -> (bundleID: String, processIdentifier: pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }
        return (bundleID, app.processIdentifier)
    }
}

/// AppleScript executor abstraction (facilitates injecting stand-ins in a GUI-less environment).
public protocol AppleScriptRunning: Sendable {
    /// Returns the list of strings output by the script; returns `nil` on failure or timeout.
    func run(_ source: String, timeout: Duration) async -> [String]?
}

/// Browser type determination.
public enum BrowserFamily: Sendable, Equatable {
    case chromium
    case safari
    /// Non-standard Scriptable browsers (Firefox / Zen, etc.) follow the AXUIElement fallback path.
    case accessibility

    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.pushplaylabs.sidekick",
    ]

    private static let safariBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    private static let accessibilityBundleIDs: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen",
    ]

    public static func family(forBundleID bundleID: String) -> BrowserFamily? {
        if chromiumBundleIDs.contains(bundleID) { return .chromium }
        if safariBundleIDs.contains(bundleID) { return .safari }
        if accessibilityBundleIDs.contains(bundleID) { return .accessibility }
        return nil
    }

    /// AppleScript target reference for scripting engines.
    public static func scriptTarget(forBundleID bundleID: String) -> String {
        "application id \"\(bundleID)\""
    }
}

/// Silent Tracing Engine: Retrieve the original Web URL and title the moment you release a drag.
public struct BrowserContextExtractor: Sendable {
    /// Strictly exceed the budget. If timeout occurs, silently degrade immediately, never blocking the main storage process.
    public static let timeout: Duration = .milliseconds(150)

    private let frontmostApp: FrontmostAppProviding
    private let scripting: AppleScriptRunning
    private let axReader: AXBrowserReading?

    public init(
        frontmostApp: FrontmostAppProviding = WorkspaceFrontmostApp(),
        scripting: AppleScriptRunning = NSAppleScriptRunner(),
        axReader: AXBrowserReading? = AXBrowserReader()
    ) {
        self.frontmostApp = frontmostApp
        self.scripting = scripting
        self.axReader = axReader
    }

    /// The default entry point of `BrowserContextProviding`.
    public func captureContext() async -> SourceContext {
        await captureContext(now: Date())
    }

    /// Regardless of success or failure, it returns a persistable `SourceContext` (in the worst case, it only records the source App).
    ///
    /// - Parameter timeout: tracing budget. The main link uses 150ms (cannot block dragging),
    ///   The global fallback this time is manually triggered by the user and is not sensitive to latency, so time can be relaxed for the automated authorization popup.
    public func captureContext(
        now: Date,
        timeout: Duration = BrowserContextExtractor.timeout
    ) async -> SourceContext {
        guard let frontmost = frontmostApp.frontmostApplication() else {
            return SourceContext(appBundleID: "unknown", capturedAt: now)
        }
        guard let family = BrowserFamily.family(forBundleID: frontmost.bundleID) else {
            return SourceContext(appBundleID: frontmost.bundleID, capturedAt: now)
        }

        var scripted: SourceContext?
        switch family {
        case .chromium:
            let script = """
            tell \(BrowserFamily.scriptTarget(forBundleID: frontmost.bundleID))
                return {URL of active tab of front window, title of active tab of front window}
            end tell
            """
            scripted = await interpret(await scripting.run(script, timeout: timeout), now: now, bundleID: frontmost.bundleID)
        case .safari:
            let script = """
            tell \(BrowserFamily.scriptTarget(forBundleID: frontmost.bundleID))
                return {URL of current tab of front window, name of current tab of front window}
            end tell
            """
            scripted = await interpret(await scripting.run(script, timeout: timeout), now: now, bundleID: frontmost.bundleID)
        case .accessibility:
            break
        }
        if let scripted { return scripted }

        // AppleScript is not available (most common reason: missing "Automation" permission, Error code is usually -1743),
        // Return to accessibility to read the address bar — this path only requires 'Accessibility' permission and is an independent second route.
        if let axReader,
           let snapshot = await axReader.readAddressBar(processIdentifier: frontmost.processIdentifier) {
            NovPoolDiagnostics.log("Provenance: falling back to AX address bar (url=\(snapshot.url?.absoluteString ?? "none"))")
            return SourceContext(
                appBundleID: frontmost.bundleID,
                pageURL: snapshot.url,
                pageTitle: snapshot.title,
                capturedAt: now
            )
        }

        return SourceContext(appBundleID: frontmost.bundleID, capturedAt: now)
    }

    private func interpret(
        _ output: [String]?,
        now: Date,
        bundleID: String
    ) async -> SourceContext? {
        guard let output, let rawURL = output.first else { return nil }
        guard let url = Self.normalizeURL(rawURL) else {
            // Record the original values to avoid issues like 'Script succeeded but was silently filtered' being difficult to trace again.
            NovPoolDiagnostics.log("Provenance: ignoring unrecognized URL \"\(rawURL)\"")
            return nil
        }
        let title = output.count > 1 ? Self.normalizeTitle(output[1]) : nil
        return SourceContext(appBundleID: bundleID, pageURL: url, pageTitle: title, capturedAt: now)
    }

    // MARK: - Pure function (testable)

    /// The script's return value may contain whitespace or be contaminated, so strict validation is performed here.
    public static func normalizeURL(_ raw: String) -> URL? {
        URLNormalization.httpURL(from: raw)
    }

    public static func normalizeTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Only accept http(s) URLs that can be safely archived: reject `mailto:`, `javascript:`, `about:`, etc.
/// Also rejects pollutant values that contain blanks (AppleScript / AX often returns entire sections of content with blanks).
enum URLNormalization {
    static func httpURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        // Browser tabs often point to local HTML files (file://), and these kinds of pages are also worth archiving.
        // You can't discard it just because it's not http(s).
        if scheme == "file" { return url }
        guard scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty else {
            return nil
        }
        return url
    }
}

// MARK: - AppleScript Execution

public struct NSAppleScriptRunner: AppleScriptRunning {
    public init() {}

    public func run(_ source: String, timeout: Duration) async -> [String]? {
        let gate = TimeoutGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
            Task.detached(priority: .userInitiated) {
                let output = Self.execute(source)
                if gate.claim() { continuation.resume(returning: output) }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                // After a timeout, the script may still finish in the background, but the results are discarded and the main process is not blocked.
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    static func execute(_ source: String) -> [String]? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -1743 usually means "Unauthorized automation," the rest are script or application errors.
            NovPoolDiagnostics.log("AppleScript failed: \(errorInfo)")
            return nil
        }
        if descriptor.descriptorType == typeNull { return nil }
        if descriptor.numberOfItems > 0 {
            return (1...descriptor.numberOfItems).compactMap { index in
                descriptor.atIndex(index)?.stringValue
            }
        }
        return descriptor.stringValue.map { [$0] }
    }
}

/// One-time victory marker, ensures that continuation is resumed only once.
final class TimeoutGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - AXUIElement downgrade path

public struct AXBrowserSnapshot: Sendable, Equatable {
    public let url: URL?
    public let title: String?
}

/// Read the currently selected text in the front-end application (Accessibility API).
///
/// In the global drag-and-drop fallback path used to answer 'what exactly did the user drag': when dragging the selected text,
/// The `AXSelectedText` of the focused element is the content being dragged. "Accessibility" permission is required.
public struct AXSelectionReader: Sendable {
    public init() {}

    public func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let element = focused else {
            return nil
        }
        let axElement = element as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success, let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public protocol AXBrowserReading: Sendable {
    func readAddressBar(processIdentifier: pid_t) async -> AXBrowserSnapshot?
}

/// Read the address bar text through the accessibility API (browsers like Firefox/Zen that do not support AppleScript).
///
/// Requires 'Accessibility' permission; returns `nil` instead of throwing an error when unauthorized.
public struct AXBrowserReader: AXBrowserReading {
    public init() {}

    public func readAddressBar(processIdentifier: pid_t) async -> AXBrowserSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let window: AXUIElement = Self.copyAttribute(application, kAXFocusedWindowAttribute) else {
            return nil
        }
        let title: String? = Self.copyAttribute(window, kAXTitleAttribute)
        let candidates = Self.addressBarCandidates(in: window, depth: 0, budget: 256)
        let url = candidates.compactMap(BrowserContextExtractor.normalizeURL).first
            ?? candidates.compactMap(Self.normalizeLooseURL).first
        return AXBrowserSnapshot(url: url, title: title)
    }

    /// Depth-first traversal with limited breadth: Only collect the Text values of AXTextField / AXComboBox.
    private static func addressBarCandidates(in element: AXUIElement, depth: Int, budget: Int) -> [String] {
        guard depth <= 4, budget > 0 else { return [] }
        var results: [String] = []
        if let role: String = copyAttribute(element, kAXRoleAttribute),
           role == (kAXTextFieldRole as String) || role == "AXComboBox",
           let value: String = copyAttribute(element, kAXValueAttribute),
           !value.isEmpty {
            results.append(value)
        }
        guard let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) else {
            return results
        }
        var remaining = budget - 1
        for child in children where remaining > 0 {
            let nested = addressBarCandidates(in: child, depth: depth + 1, budget: remaining)
            remaining -= max(1, nested.count)
            results.append(contentsOf: nested)
        }
        return results
    }

    private static func normalizeLooseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard trimmed.contains(".") else { return nil }
        return URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
    }

    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }
}
