import AppKit
import ApplicationServices
import Foundation
import NovPoolCore

/// 前台应用信息提供者（真实实现读 `NSWorkspace`）。
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

/// AppleScript 执行器抽象（便于在无 GUI 环境中注入替身）。
public protocol AppleScriptRunning: Sendable {
    /// 返回脚本输出的字符串列表；失败或超时返回 `nil`。
    func run(_ source: String, timeout: Duration) async -> [String]?
}

/// 浏览器类型判定。
public enum BrowserFamily: Sendable, Equatable {
    case chromium
    case safari
    /// 非标准 Scriptable 浏览器（Firefox / Zen 等），走 AXUIElement 降级路径。
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

    /// 面向脚本引擎的 AppleScript 目标引用。
    public static func scriptTarget(forBundleID bundleID: String) -> String {
        "application id \"\(bundleID)\""
    }
}

/// 静默溯源引擎：在拖拽松手瞬间取回原网页 URL 与标题。
public struct BrowserContextExtractor: Sendable {
    /// 硬超时预算。超时立即静默降级，绝不阻塞入库主流程。
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

    /// `BrowserContextProviding` 的默认入口。
    public func captureContext() async -> SourceContext {
        await captureContext(now: Date())
    }

    /// 无论成功与否都返回可持久化的 `SourceContext`（最差情况只记录来源 App）。
    ///
    /// - Parameter timeout: 溯源预算。主链路用 150ms（不能阻塞拖拽），
    ///   全局兜底这次是用户手动触发、对延迟不敏感，可以放宽给自动化授权弹窗留时间。
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

        // AppleScript 不可用（最常见原因：缺「自动化」授权，错误码通常是 -1743）时，
        // 退回辅助功能读地址栏——这条路径只需要「辅助功能」授权，是独立的第二条通路。
        if let axReader,
           let snapshot = await axReader.readAddressBar(processIdentifier: frontmost.processIdentifier) {
            NovPoolDiagnostics.log("溯源：改用 AX 地址栏（url=\(snapshot.url?.absoluteString ?? "无")）")
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
            // 记录原始值，避免"脚本成功但被静默过滤"这类问题再次难查。
            NovPoolDiagnostics.log("溯源：忽略无法识别的 URL「\(rawURL)」")
            return nil
        }
        let title = output.count > 1 ? Self.normalizeTitle(output[1]) : nil
        return SourceContext(appBundleID: bundleID, pageURL: url, pageTitle: title, capturedAt: now)
    }

    // MARK: - 纯函数（可单测）

    /// 脚本返回值可能带空白或被污染，这里做严格校验。
    public static func normalizeURL(_ raw: String) -> URL? {
        URLNormalization.httpURL(from: raw)
    }

    public static func normalizeTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 只接受可安全归档的 http(s) URL：拒绝 `mailto:`、`javascript:`、`about:` 等，
/// 也拒绝含空白的污染值（AppleScript / AX 常常回传整段带空白的内容）。
enum URLNormalization {
    static func httpURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        // 浏览器标签常常指向本机 HTML 文件（file://），这类页面同样值得归档，
        // 不能因为不是 http(s) 就丢掉。
        if scheme == "file" { return url }
        guard scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty else {
            return nil
        }
        return url
    }
}

// MARK: - AppleScript 执行

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
                // 超时后脚本仍可能在后台结束，但结果被丢弃，主流程不被阻塞。
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    static func execute(_ source: String) -> [String]? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -1743 通常是「未授权自动化」，其余是脚本或应用错误。
            NovPoolDiagnostics.log("AppleScript 失败：\(errorInfo)")
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

/// 一次性获胜标记，保证 continuation 只被 resume 一次。
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

// MARK: - AXUIElement 降级路径

public struct AXBrowserSnapshot: Sendable, Equatable {
    public let url: URL?
    public let title: String?
}

/// 读取前台应用当前选中的文本（辅助功能 API）。
///
/// 全局拖拽兜底通路里用来回答「用户到底拖了什么」：拖选中的文字时，
/// 焦点元素的 `AXSelectedText` 就是被拖的内容。需要「辅助功能」授权。
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

/// 通过辅助功能 API 读取地址栏文本（Firefox / Zen 等不支持 AppleScript 的浏览器）。
///
/// 需要「辅助功能」授权；未授权时返回 `nil` 而非报错。
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

    /// 广度受限的深度优先遍历：只收集 AXTextField / AXComboBox 的文本值。
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
