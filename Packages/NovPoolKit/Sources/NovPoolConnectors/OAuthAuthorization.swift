import Foundation
import NovPoolCore
import NovPoolStorage

/// Definition of browser authorization process provider (endpoints, scope, callback method).
public struct OAuthProviderDefinition: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case googleDrive
        case microsoftOneDrive
        case notion
    }

    public var kind: Kind
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var scope: String
    /// Notion's token exchange requires Basic authentication (client_id:client_secret).
    public var usesBasicAuthForTokenExchange: Bool
    /// Whether the authorization response contains a refresh token (Notion returns a long-term token).
    public var returnsRefreshToken: Bool
    public var extraAuthorizationParameters: [String: String]

    public static let callbackScheme = "novpool"
    public static let redirectURI = "novpool://oauth"

    public static func google(clientID: String) -> OAuthProviderDefinition {
        OAuthProviderDefinition(
            kind: .googleDrive,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            scope: "https://www.googleapis.com/auth/drive.file",
            usesBasicAuthForTokenExchange: false,
            returnsRefreshToken: true,
            extraAuthorizationParameters: [
                "access_type": "offline",
                "prompt": "consent",
                "include_granted_scopes": "true",
            ]
        )
    }

    public static func microsoft(clientID: String, tenant: String?) -> OAuthProviderDefinition {
        let tenantValue = (tenant?.isEmpty == false ? tenant! : "common")
        return OAuthProviderDefinition(
            kind: .microsoftOneDrive,
            authorizationEndpoint: URL(string:
                "https://login.microsoftonline.com/\(tenantValue)/oauth2/v2.0/authorize"
            )!,
            tokenEndpoint: URL(string:
                "https://login.microsoftonline.com/\(tenantValue)/oauth2/v2.0/token"
            )!,
            scope: "https://graph.microsoft.com/Files.ReadWrite offline_access",
            usesBasicAuthForTokenExchange: false,
            returnsRefreshToken: true,
            extraAuthorizationParameters: ["prompt": "select_account"]
        )
    }

    public static func notion(clientID: String) -> OAuthProviderDefinition {
        OAuthProviderDefinition(
            kind: .notion,
            authorizationEndpoint: URL(string: "https://api.notion.com/v1/oauth/authorize")!,
            tokenEndpoint: URL(string: "https://api.notion.com/v1/oauth/token")!,
            scope: "",
            usesBasicAuthForTokenExchange: true,
            returnsRefreshToken: false,
            extraAuthorizationParameters: ["owner": "user"]
        )
    }

    /// Assemble the authorization address that the browser needs to open.
    public func authorizationURL(
        clientID: String,
        codeChallenge: String,
        state: String,
        redirectURI: String = OAuthProviderDefinition.redirectURI
    ) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        if !scope.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scope))
        }
        if !usesBasicAuthForTokenExchange {
            items.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        for (key, value) in extraAuthorizationParameters.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        return components.url!
    }
}

/// Authorization callback parsing (`novpool://oauth?code=…&state=…`).
public enum OAuthCallbackParser {
    public enum Failure: Error, Equatable, LocalizedError {
        case providerError(String)
        case stateMismatch
        case missingCode

        public var errorDescription: String? {
            switch self {
            case .providerError(let detail): "Authorization denied: \(detail)"
            case .stateMismatch: "OAuth callback state mismatch; rejected (possible forged callback)"
            case .missingCode: "Authorization callback has no code"
            }
        }
    }

    public static func authorizationCode(from url: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        if let error = items["error"] {
            let description = items["error_description"] ?? error
            throw Failure.providerError(description)
        }
        if let state = items["state"], state != expectedState {
            throw Failure.stateMismatch
        }
        guard let code = items["code"], !code.isEmpty else {
            throw Failure.missingCode
        }
        return code
    }
}

/// Open the browser to complete the authorization and retrieve the callback address.
public protocol BrowserAuthorizationSession: Sendable {
    func authorize(url: URL, callbackURLScheme: String) async throws -> URL
}

/// Credential storage abstraction (use `KeychainStore` for production, in-memory substitute for testing).
public protocol CredentialStoring: Sendable {
    func store(_ secret: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
}

extension KeychainStore: CredentialStoring {}

/// Authorized orchestration: browser login → exchange token → writeKeychain → register connector.
///
/// The user only needs to click "Authorize with Browser" once; the client ID belongs to the application configuration and only needs to be filled in once.
public struct ConnectorAuthorizationCoordinator: Sendable {
    public struct Outcome: Sendable, Equatable {
        public var connectorID: String
        public var account: String
        public var detail: String
    }

    private let session: any BrowserAuthorizationSession
    private let tokenService: OAuthTokenService
    private let credentials: any CredentialStoring
    private let connectorRepository: ConnectorRepository
    private let transport: any HTTPTransport
    private let makeState: @Sendable () -> String

    public init(
        session: any BrowserAuthorizationSession,
        credentials: any CredentialStoring = KeychainStore(),
        connectorRepository: ConnectorRepository,
        transport: any HTTPTransport = URLSessionTransport(),
        makeState: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.session = session
        self.credentials = credentials
        self.connectorRepository = connectorRepository
        self.transport = transport
        self.tokenService = OAuthTokenService(transport: transport)
        self.makeState = makeState
    }

    /// Google Drive / OneDrive: Standard PKCE authorization code flow to get a refresh token.
    public func authorizeOAuthConnector(
        connectorID: String,
        name: String,
        type: String,
        definition: OAuthProviderDefinition,
        provider: OAuthProviderKind,
        clientID: String,
        clientSecret: String?,
        tenant: String?,
        targetPath: String?
    ) async throws -> Outcome {
        guard !clientID.isEmpty else {
            throw NovPoolError.connectorNotConfigured("Missing OAuth Client ID (app config; fill in once)")
        }
        let verifier = PKCE.codeVerifier()
        let state = makeState()
        let authorizationURL = definition.authorizationURL(
            clientID: clientID,
            codeChallenge: PKCE.codeChallenge(for: verifier),
            state: state
        )
        let callback = try await session.authorize(
            url: authorizationURL,
            callbackURLScheme: OAuthProviderDefinition.callbackScheme
        )
        let code = try OAuthCallbackParser.authorizationCode(from: callback, expectedState: state)

        let placeholder = OAuthCredentials(
            provider: provider,
            clientID: clientID,
            clientSecret: clientSecret,
            refreshToken: "",
            tenant: tenant,
            targetPath: targetPath
        )
        let authorized = try await tokenService.exchange(
            authorizationCode: code,
            codeVerifier: verifier,
            credentials: placeholder,
            redirectURI: OAuthProviderDefinition.redirectURI
        )
        guard !authorized.refreshToken.isEmpty else {
            throw NovPoolError.authenticationRequired("Authorization completed but the server did not return a refresh token")
        }

        let account = "\(connectorID).oauth"
        try credentials.store(try authorized.encoded(), account: account)
        let config = OAuthConnectorConfig(folderPath: targetPath, tenant: tenant)
        try await writeConnector(
            id: connectorID,
            name: name,
            type: type,
            account: account,
            configJSON: try config.encodedJSON()
        )
        return Outcome(connectorID: connectorID, account: account, detail: "Authorized and registered \(name)")
    }

    /// Notion: Use authorization code to exchange for a long-term token (use Basic authentication during the exchange).
    public func authorizeNotionConnector(
        connectorID: String,
        name: String,
        definition: OAuthProviderDefinition,
        clientID: String,
        clientSecret: String,
        config: NotionConnector.Config
    ) async throws -> Outcome {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw NovPoolError.connectorNotConfigured("Notion authorization needs the Integration Client ID and Secret (app config)")
        }
        let state = makeState()
        let authorizationURL = definition.authorizationURL(
            clientID: clientID,
            codeChallenge: "",
            state: state
        )
        let callback = try await session.authorize(
            url: authorizationURL,
            callbackURLScheme: OAuthProviderDefinition.callbackScheme
        )
        let code = try OAuthCallbackParser.authorizationCode(from: callback, expectedState: state)

        var request = URLRequest(url: definition.tokenEndpoint)
        request.httpMethod = "POST"
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OAuthProviderDefinition.redirectURI,
        ])

        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty else {
            let detail = SecretRedactor.redact(String(decoding: response.body.prefix(200), as: UTF8.self))
            throw NovPoolError.authenticationRequired("Notion token exchange failed (HTTP\(response.statusCode)): \(detail)")
        }

        let account = "\(connectorID).token"
        try credentials.store(Data(token.utf8), account: account)
        try await writeConnector(
            id: connectorID,
            name: name,
            type: "notion",
            account: account,
            configJSON: String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        )
        let workspace = object["workspace_name"] as? String
        return Outcome(
            connectorID: connectorID,
            account: account,
            detail: workspace.map { "Authorized Notion workspace: \($0)" } ?? "Authorized and registered Notion"
        )
    }

    func writeConnector(
        id: String,
        name: String,
        type: String,
        account: String,
        configJSON: String
    ) async throws {
        try await connectorRepository.upsert(ConnectorRecord(
            id: id,
            name: name,
            connectorType: type,
            keychainAccountRef: account,
            configJSON: configJSON
        ))
    }
}
