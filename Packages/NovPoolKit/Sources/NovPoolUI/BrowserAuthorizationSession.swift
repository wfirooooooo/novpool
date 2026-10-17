import AppKit
import AuthenticationServices
import Foundation
import NovPoolConnectors
import NovPoolCore

/// 用系统浏览器完成 OAuth 授权（`ASWebAuthenticationSession`）。
///
/// 走系统组件而不是内置 WebView：用户能直接用浏览器里已有的登录态，
/// 不需要在应用里再输一次账号密码，密码也不会经过本应用。
@MainActor
public struct WebBrowserAuthorizationSession: BrowserAuthorizationSession {
    private let anchorProvider: @MainActor @Sendable () -> NSWindow?
    private let logger: (@Sendable (String) -> Void)?

    public init(
        anchorProvider: (@MainActor @Sendable () -> NSWindow?)? = nil,
        logger: (@Sendable (String) -> Void)? = nil
    ) {
        self.anchorProvider = anchorProvider ?? Self.defaultAnchor
        self.logger = logger
    }

    /// 优先用常规窗口（设置窗口）做 anchor。
    ///
    /// 菜单栏应用里"第一个可见窗口"很可能是那个 `.nonactivatingPanel` 悬浮窗，
    /// 用它做 anchor 会导致授权窗口弹不出来——所以这里按「key → 常规窗口 → 任意可见」挑。
    @MainActor
    static func defaultAnchor() -> NSWindow? {
        if let key = NSApp.keyWindow, key.isVisible { return key }
        if let regular = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            return regular
        }
        return NSApp.windows.first { $0.isVisible && !($0 is NSPanel) } ?? NSApp.windows.first { $0.isVisible }
    }

    public func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        logger?("授权：打开浏览器 \(url.host() ?? "") 回调 scheme=\(callbackURLScheme)")
        // ASWebAuthenticationSession 必须一直被持有到回调发生，否则系统会立刻取消流程；
        // presentationContextProvider 还是 weak 引用，anchor 也必须自己保住。
        let keeper = SessionKeeper()
        return try await withCheckedThrowingContinuation { continuation in
            let anchor = anchorProvider()
            logger?("授权：presentation anchor = \(anchor.map { "\(type(of: $0))" } ?? "无（可能弹不出窗口）")")
            let contextProvider = AnchorProvider(window: anchor)
            keeper.contextProvider = contextProvider

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { callbackURL, error in
                defer { keeper.finish() }
                if let callbackURL {
                    // 只记 scheme/host，避免把授权码写进日志。
                    self.logger?("授权：收到回调 \(callbackURL.scheme ?? "")://\(callbackURL.host() ?? "")")
                    continuation.resume(returning: callbackURL)
                    return
                }
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    self.logger?("授权：用户取消")
                    continuation.resume(throwing: NovPoolError.authenticationRequired("授权被取消"))
                    return
                }
                self.logger?("授权：失败 \(error?.localizedDescription ?? "未知错误")")
                continuation.resume(throwing: NovPoolError.authenticationRequired(
                    "浏览器授权失败：\(error?.localizedDescription ?? "未知错误")"
                ))
            }
            keeper.session = session
            // 复用浏览器已有登录态；不启用隐私模式。
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = contextProvider
            if !session.start() {
                logger?("授权：session.start() 返回 false（无法打开授权窗口）")
                continuation.resume(throwing: NovPoolError.authenticationRequired("无法打开浏览器授权窗口"))
            } else {
                logger?("授权：浏览器窗口已打开，等待用户完成登录")
            }
        }
    }

    /// 在授权流程期间持有 session 与 anchor。
    private final class SessionKeeper: @unchecked Sendable {
        var session: ASWebAuthenticationSession?
        var contextProvider: AnchorProvider?

        func finish() {
            session = nil
            contextProvider = nil
        }
    }

    private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        private let window: NSWindow?

        init(window: NSWindow?) {
            self.window = window
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            window ?? ASPresentationAnchor()
        }
    }
}
