import AppKit
import AuthenticationServices
import Foundation
import NovPoolConnectors
import NovPoolCore

/// Complete OAuth authorization using the system browser (`ASWebAuthenticationSession`).
///
/// Use system components instead of the built-in WebView: users can directly use the login status already present in the browser.
/// There is no need to enter your account and password again in the app, and the password will not go through this app.
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

    /// Prefer to use the regular window (settings window) as the anchor.
    ///
    /// In the menu bar application, the 'First visible window' is most likely that `.nonactivatingPanel` floating window,
    /// Using it as an anchor will cause the authorization window not to pop up—so here, press 'key → normal window → any visible' to select.
    @MainActor
    static func defaultAnchor() -> NSWindow? {
        if let key = NSApp.keyWindow, key.isVisible { return key }
        if let regular = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            return regular
        }
        return NSApp.windows.first { $0.isVisible && !($0 is NSPanel) } ?? NSApp.windows.first { $0.isVisible }
    }

    public func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        logger?("Auth: open browser\(url.host() ?? "")  callback scheme=\(callbackURLScheme)")
        // ASWebAuthenticationSession must be retained until the callback occurs; otherwise, the system will immediately cancel the process.
        // presentationContextProvider is still a weak reference, and the anchor must also be kept by yourself.
        let keeper = SessionKeeper()
        return try await withCheckedThrowingContinuation { continuation in
            let anchor = anchorProvider()
            logger?("Auth: presentation anchor =\(anchor.map { "\(type(of: $0))" } ?? "none (window may not appear)")")
            let contextProvider = AnchorProvider(window: anchor)
            keeper.contextProvider = contextProvider

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { callbackURL, error in
                defer { keeper.finish() }
                if let callbackURL {
                    // Only record the scheme/host, and avoid writing the authorization code into the logs.
                    self.logger?("Auth: received callback\(callbackURL.scheme ?? "")://\(callbackURL.host() ?? "")")
                    continuation.resume(returning: callbackURL)
                    return
                }
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    self.logger?("Auth: user canceled")
                    continuation.resume(throwing: NovPoolError.authenticationRequired("Authorization canceled"))
                    return
                }
                self.logger?("Auth: failed\(error?.localizedDescription ?? "unknown error")")
                continuation.resume(throwing: NovPoolError.authenticationRequired(
                    "Browser authorization failed: \(error?.localizedDescription ?? "unknown error")"
                ))
            }
            keeper.session = session
            // Reuse the existing login state of the browser; do not enable private mode.
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = contextProvider
            if !session.start() {
                logger?("Auth: session.start() returned false (could not open auth window)")
                continuation.resume(throwing: NovPoolError.authenticationRequired("Could not open the browser authorization window"))
            } else {
                logger?("Auth: browser window opened; waiting for user to finish login")
            }
        }
    }

    /// Hold session and anchor during the authorization process.
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
