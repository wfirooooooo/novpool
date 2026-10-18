import CryptoKit
import Foundation
import NovPoolCore

public enum OAuthProviderKind: String, Sendable, Codable {
    case google
    case microsoft
}

/// OAuth 2.0 credentials. Stored in the Keychain as JSON—**never in the database**.
public struct OAuthCredentials: Sendable, Equatable, Codable {
    public var provider: OAuthProviderKind
    public var clientID: String
    public var clientSecret: String?
    public var refreshToken: String
    public var tenant: String?
    /// Target directory on the cloud drive (use folderID for Drive; use path for OneDrive).
    public var targetPath: String?

    public init(
        provider: OAuthProviderKind,
        clientID: String,
        clientSecret: String? = nil,
        refreshToken: String,
        tenant: String? = nil,
        targetPath: String? = nil
    ) {
        self.provider = provider
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
        self.tenant = tenant
        self.targetPath = targetPath
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(_ data: Data) -> OAuthCredentials? {
        try? JSONDecoder().decode(OAuthCredentials.self, from: data)
    }

    /// Token endpoint.
    public var tokenEndpoint: URL {
        switch provider {
        case .google:
            URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft:
            URL(string: "https://login.microsoftonline.com/\(tenant ?? "common")/oauth2/v2.0/token")!
        }
    }

    public var scope: String {
        switch provider {
        case .google:
            "https://www.googleapis.com/auth/drive.file"
        case .microsoft:
            "https://graph.microsoft.com/Files.ReadWrite offline_access"
        }
    }
}

/// PKCE (RFC 7636): Generates a one-time verification value for the authorization code flow of native applications.
public enum PKCE {
    /// code_verifier: 43–128 URL-safe characters.
    public static func codeVerifier(byteCount: Int = 48) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return base64URLEncode(Data(bytes))
    }

    /// code_challenge = BASE64URL(SHA256(verifier)).
    public static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Token service: refresh the access token and assemble the request to exchange the authorization code for a token.
public struct OAuthTokenService: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Use a refresh token to exchange for an access token.
    public func accessToken(
        credentials: OAuthCredentials,
        now: Date = Date()
    ) async throws -> String {
        guard !credentials.refreshToken.isEmpty else {
            throw NovPoolError.authenticationRequired("Missing refresh token; complete authorization first")
        }
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": credentials.clientID,
        ]
        if let secret = credentials.clientSecret { body["client_secret"] = secret }
        if credentials.provider == .microsoft { body["scope"] = credentials.scope }

        let payload = try await postForm(credentials.tokenEndpoint, body)
        guard let object = (try? JSONSerialization.jsonObject(with: payload.body)) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty else {
            let detail = SecretRedactor.redact(String(decoding: payload.body.prefix(200), as: UTF8.self))
            throw NovPoolError.authenticationRequired("Refresh token failed (HTTP\(payload.statusCode)): \(detail)")
        }
        return token
    }

    /// Exchange authorization code for token (used after the authorization process callback).
    public func exchange(
        authorizationCode: String,
        codeVerifier: String,
        credentials: OAuthCredentials,
        redirectURI: String
    ) async throws -> OAuthCredentials {
        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": authorizationCode,
            "code_verifier": codeVerifier,
            "client_id": credentials.clientID,
            "redirect_uri": redirectURI,
        ]
        if let secret = credentials.clientSecret { body["client_secret"] = secret }

        let payload = try await postForm(credentials.tokenEndpoint, body)
        guard let object = (try? JSONSerialization.jsonObject(with: payload.body)) as? [String: Any],
              let refreshToken = object["refresh_token"] as? String else {
            let detail = SecretRedactor.redact(String(decoding: payload.body.prefix(200), as: UTF8.self))
            throw NovPoolError.authenticationRequired("Token exchange failed (HTTP\(payload.statusCode)): \(detail)")
        }
        var updated = credentials
        updated.refreshToken = refreshToken
        return updated
    }

    private func postForm(_ url: URL, _ fields: [String: String]) async throws -> HTTPPayload {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return try await transport.send(request)
    }
}

/// Authorization address construction (for `ASWebAuthenticationSession` Open).
public enum OAuthAuthorizationRequest {
    public static func url(
        credentials: OAuthCredentials,
        codeChallenge: String,
        redirectURI: String,
        state: String
    ) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        switch credentials.provider {
        case .google:
            components.host = "accounts.google.com"
            components.path = "/o/oauth2/v2/auth"
        case .microsoft:
            components.host = "login.microsoftonline.com"
            components.path = "/\(credentials.tenant ?? "common")/oauth2/v2.0/authorize"
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: credentials.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }
}
