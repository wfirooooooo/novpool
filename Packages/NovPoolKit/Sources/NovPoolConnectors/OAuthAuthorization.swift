import Foundation
import NovPoolCore
import NovPoolStorage

/// 浏览器授权流程的提供方定义（端点、scope、回调方式）。
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
    /// Notion 的 token 交换要求 Basic 认证（client_id:client_secret）。
    public var usesBasicAuthForTokenExchange: Bool
    /// 授权响应里是否含 refresh token（Notion 返回的是长期 token）。
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

    /// 拼出浏览器要打开的授权地址。
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

/// 授权回调解析（`novpool://oauth?code=…&state=…`）。
public enum OAuthCallbackParser {
    public enum Failure: Error, Equatable, LocalizedError {
        case providerError(String)
        case stateMismatch
        case missingCode

        public var errorDescription: String? {
            switch self {
            case .providerError(let detail): "授权被拒绝：\(detail)"
            case .stateMismatch: "授权回调的 state 不匹配，已拒绝（可能是伪造回调）"
            case .missingCode: "授权回调里没有 code"
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

/// 打开浏览器完成授权、并拿回回调地址。
public protocol BrowserAuthorizationSession: Sendable {
    func authorize(url: URL, callbackURLScheme: String) async throws -> URL
}

/// 凭据存储抽象（生产用 `KeychainStore`，测试用内存替身）。
public protocol CredentialStoring: Sendable {
    func store(_ secret: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
}

extension KeychainStore: CredentialStoring {}

/// 授权编排：浏览器登录 → 换取令牌 → 写入钥匙串 → 登记连接器。
///
/// 用户只需要点一次「用浏览器授权」；client ID 属于应用配置，填一次即可。
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

    /// Google Drive / OneDrive：标准 PKCE 授权码流程，拿 refresh token。
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
            throw NovPoolError.connectorNotConfigured("缺少 OAuth Client ID（属于应用配置，填一次即可）")
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
            throw NovPoolError.authenticationRequired("授权已完成，但服务端没有返回 refresh token")
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
        return Outcome(connectorID: connectorID, account: account, detail: "已授权并登记 \(name)")
    }

    /// Notion：授权码换长期 token（交换时用 Basic 认证）。
    public func authorizeNotionConnector(
        connectorID: String,
        name: String,
        definition: OAuthProviderDefinition,
        clientID: String,
        clientSecret: String,
        config: NotionConnector.Config
    ) async throws -> Outcome {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw NovPoolError.connectorNotConfigured("Notion 授权需要 Integration 的 Client ID 与 Secret（应用配置）")
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
            let detail = String(decoding: response.body.prefix(200), as: UTF8.self)
            throw NovPoolError.authenticationRequired("Notion 换取令牌失败（HTTP \(response.statusCode)）：\(detail)")
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
            detail: workspace.map { "已授权 Notion 工作区：\($0)" } ?? "已授权并登记 Notion"
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
