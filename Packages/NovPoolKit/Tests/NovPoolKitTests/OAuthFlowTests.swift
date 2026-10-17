import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolConnectors

/// 模拟浏览器授权：直接返回一个带 code 的回调地址。
struct FakeBrowserSession: BrowserAuthorizationSession {
    struct Cancelled: Error {}
    var callbackURL: URL
    var shouldCancel = false
    var expectedScheme: String?

    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        if shouldCancel { throw Cancelled() }
        return callbackURL
    }
}

/// 内存凭据存储（沙盒里钥匙串不可用，用它验证编排逻辑）。
final class InMemoryCredentials: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func store(_ secret: Data, account: String) throws {
        withLock { storage[account] = secret }
    }

    func load(account: String) throws -> Data? {
        withLock { storage[account] }
    }

    func delete(account: String) throws {
        _ = withLock { storage.removeValue(forKey: account) }
    }

    func secret(for account: String) -> Data? { try? load(account: account) }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@Suite("浏览器授权流程")
struct OAuthFlowTests {
    // MARK: - 回调解析

    @Test("回调解析：取出 code，校验 state")
    func callbackParsing() throws {
        let url = URL(string: "novpool://oauth?code=abc123&state=st-1")!
        #expect(try OAuthCallbackParser.authorizationCode(from: url, expectedState: "st-1") == "abc123")
    }

    @Test("回调解析：state 不匹配一律拒绝（防伪造回调）")
    func callbackStateMismatch() {
        let url = URL(string: "novpool://oauth?code=abc&state=evil")!
        #expect(throws: OAuthCallbackParser.Failure.stateMismatch) {
            try OAuthCallbackParser.authorizationCode(from: url, expectedState: "st-1")
        }
    }

    @Test("回调解析：服务端拒绝与缺少 code 都有明确错误")
    func callbackErrors() {
        let denied = URL(string: "novpool://oauth?error=access_denied&error_description=用户拒绝")!
        #expect(throws: OAuthCallbackParser.Failure.providerError("用户拒绝")) {
            try OAuthCallbackParser.authorizationCode(from: denied, expectedState: "s")
        }
        let empty = URL(string: "novpool://oauth?state=s")!
        #expect(throws: OAuthCallbackParser.Failure.missingCode) {
            try OAuthCallbackParser.authorizationCode(from: empty, expectedState: "s")
        }
    }

    // MARK: - 授权地址

    @Test("Google 授权地址带 PKCE 与离线访问参数")
    func googleAuthorizationURL() throws {
        let url = OAuthProviderDefinition.google(clientID: "cid").authorizationURL(
            clientID: "cid",
            codeChallenge: "chal",
            state: "st"
        )
        let items = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }
        )
        #expect(url.host == "accounts.google.com")
        #expect(items["client_id"] == "cid")
        #expect(items["code_challenge"] == "chal")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["access_type"] == "offline")
        #expect(items["redirect_uri"] == "novpool://oauth")
        #expect(items["scope"]?.contains("drive.file") == true)
    }

    @Test("Microsoft 授权地址跟随租户；Notion 不带 PKCE 但带 owner")
    func otherProviderURLs() throws {
        let microsoft = OAuthProviderDefinition.microsoft(clientID: "cid", tenant: "contoso")
        #expect(microsoft.authorizationEndpoint.host == "login.microsoftonline.com")
        #expect(microsoft.authorizationEndpoint.path.contains("/contoso/"))
        #expect(microsoft.scope.contains("offline_access"))

        let notion = OAuthProviderDefinition.notion(clientID: "cid").authorizationURL(
            clientID: "cid",
            codeChallenge: "",
            state: "st"
        )
        let items = (URLComponents(url: notion, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        let names = Set(items.map(\.name))
        #expect(names.contains("owner"))
        #expect(!names.contains("code_challenge"))
    }

    // MARK: - 编排

    private func makeHarness(
        callback: URL,
        tokenResponse: HTTPPayload,
        cancelled: Bool = false
    ) async throws -> (coordinator: ConnectorAuthorizationCoordinator, repository: ConnectorRepository,
                       credentials: InMemoryCredentials, transport: StubTransport, database: NovPoolDatabase) {
        let directory = try TestSupport.makeTemporaryDirectory("oauth")
        let database = try NovPoolDatabase(path: directory.appending(path: "db.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        let repository = ConnectorRepository(database: database)
        let credentials = InMemoryCredentials()
        let transport = StubTransport(responses: [tokenResponse])
        let coordinator = ConnectorAuthorizationCoordinator(
            session: FakeBrowserSession(callbackURL: callback, shouldCancel: cancelled),
            credentials: credentials,
            connectorRepository: repository,
            transport: transport,
            makeState: { "fixed-state" }
        )
        return (coordinator, repository, credentials, transport, database)
    }

    @Test("Google 授权：走完浏览器回调 → 换令牌 → 写凭据 → 登记连接器")
    func googleFlow() async throws {
        let callback = URL(string: "novpool://oauth?code=code-1&state=fixed-state")!
        let harness = try await makeHarness(
            callback: callback,
            tokenResponse: HTTPPayload(json: #"{"access_token":"at","refresh_token":"rt"}"#)
        )

        let outcome = try await harness.coordinator.authorizeOAuthConnector(
            connectorID: "gdrive",
            name: "Google Drive",
            type: "gdrive_api",
            definition: .google(clientID: "cid"),
            provider: .google,
            clientID: "cid",
            clientSecret: nil,
            tenant: nil,
            targetPath: "folder-1"
        )

        #expect(outcome.connectorID == "gdrive")
        #expect(outcome.account == "gdrive.oauth")

        // 令牌交换请求：授权码 + PKCE verifier
        let request = try #require(harness.transport.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=code-1"))
        #expect(body.contains("code_verifier="))

        // 凭据落到（内存）钥匙串，连接器登记到数据库
        let stored = try #require(harness.credentials.secret(for: "gdrive.oauth"))
        let storedCredentials = try #require(OAuthCredentials.decoded(stored))
        #expect(storedCredentials.refreshToken == "rt")
        #expect(storedCredentials.provider == .google)
        #expect(storedCredentials.targetPath == "folder-1")

        let record = try #require(try await harness.repository.fetch(id: "gdrive"))
        #expect(record.connectorType == "gdrive_api")
        #expect(record.keychainAccountRef == "gdrive.oauth")
        #expect(record.configJSON.contains("folder-1"))
    }

    @Test("OneDrive 授权：租户与目标路径写进配置")
    func oneDriveFlow() async throws {
        let callback = URL(string: "novpool://oauth?code=code-2&state=fixed-state")!
        let harness = try await makeHarness(
            callback: callback,
            tokenResponse: HTTPPayload(json: #"{"access_token":"at","refresh_token":"rt2"}"#)
        )
        _ = try await harness.coordinator.authorizeOAuthConnector(
            connectorID: "onedrive",
            name: "OneDrive",
            type: "onedrive_api",
            definition: .microsoft(clientID: "cid", tenant: "contoso"),
            provider: .microsoft,
            clientID: "cid",
            clientSecret: nil,
            tenant: "contoso",
            targetPath: "NovPool/技术"
        )
        let record = try #require(try await harness.repository.fetch(id: "onedrive"))
        #expect(record.configJSON.contains("contoso"))
        #expect(record.configJSON.contains("NovPool/技术"))
    }

    @Test("Notion 授权：Basic 认证换长期 token，按 token 方式登记")
    func notionFlow() async throws {
        let callback = URL(string: "novpool://oauth?code=code-3&state=fixed-state")!
        let harness = try await makeHarness(
            callback: callback,
            tokenResponse: HTTPPayload(json: #"{"access_token":"ntn_long","workspace_name":"我的团队"}"#)
        )

        let outcome = try await harness.coordinator.authorizeNotionConnector(
            connectorID: "notion",
            name: "Notion",
            definition: .notion(clientID: "cid"),
            clientID: "cid",
            clientSecret: "secret",
            config: NotionConnector.Config(databaseID: "db-1", titleProperty: "名称")
        )

        #expect(outcome.detail.contains("我的团队"))
        let request = try #require(harness.transport.requests.first)
        let expectedBasic = Data("cid:secret".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(expectedBasic)")
        #expect(String(decoding: try #require(harness.credentials.secret(for: "notion.token")), as: UTF8.self)
            == "ntn_long")

        let record = try #require(try await harness.repository.fetch(id: "notion"))
        #expect(record.keychainAccountRef == "notion.token")
        #expect(record.configJSON.contains("db-1"))
    }

    @Test("授权被取消时抛出可读错误，不留下半成品连接器")
    func cancelledFlow() async throws {
        let harness = try await makeHarness(
            callback: URL(string: "novpool://oauth?code=x&state=fixed-state")!,
            tokenResponse: HTTPPayload(json: "{}"),
            cancelled: true
        )
        await #expect(throws: (any Error).self) {
            _ = try await harness.coordinator.authorizeOAuthConnector(
                connectorID: "gdrive",
                name: "Google Drive",
                type: "gdrive_api",
                definition: .google(clientID: "cid"),
                provider: .google,
                clientID: "cid",
                clientSecret: nil,
                tenant: nil,
                targetPath: nil
            )
        }
        #expect(try await harness.repository.list().isEmpty)
        #expect(harness.credentials.secret(for: "gdrive.oauth") == nil)
    }

    @Test("缺少 client ID 时直接报错，不打开浏览器")
    func missingClientIDSkipsBrowser() async throws {
        let harness = try await makeHarness(
            callback: URL(string: "novpool://oauth?code=x&state=fixed-state")!,
            tokenResponse: HTTPPayload(json: "{}")
        )
        await #expect(throws: NovPoolError.self) {
            _ = try await harness.coordinator.authorizeOAuthConnector(
                connectorID: "gdrive",
                name: "Google Drive",
                type: "gdrive_api",
                definition: .google(clientID: ""),
                provider: .google,
                clientID: "",
                clientSecret: nil,
                tenant: nil,
                targetPath: nil
            )
        }
        #expect(harness.transport.requests.isEmpty)
    }
}
