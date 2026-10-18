import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolConnectors

/// Simulate browser authorization: directly return a callback URL with a code.
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

/// In-memory credential storage (Keychain is not available in the sandbox, use this to validate orchestration logic).
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

@Suite("Browser Authorization Process")
struct OAuthFlowTests {
    // MARK: - Callback Parsing

    @Test("Callback parsing: extract code, verify state")
    func callbackParsing() throws {
        let url = URL(string: "novpool://oauth?code=abc123&state=st-1")!
        #expect(try OAuthCallbackParser.authorizationCode(from: url, expectedState: "st-1") == "abc123")
    }

    @Test("Callback parsing: state mismatch will always be rejected (to prevent forged callbacks)")
    func callbackStateMismatch() {
        let url = URL(string: "novpool://oauth?code=abc&state=evil")!
        #expect(throws: OAuthCallbackParser.Failure.stateMismatch) {
            try OAuthCallbackParser.authorizationCode(from: url, expectedState: "st-1")
        }
    }

    @Test("Callback parsing: The server has clear errors for both rejection and missing code")
    func callbackErrors() {
        let denied = URL(string: "novpool://oauth?error=access_denied&error_description=User refused")!
        #expect(throws: OAuthCallbackParser.Failure.providerError("User refused")) {
            try OAuthCallbackParser.authorizationCode(from: denied, expectedState: "s")
        }
        let empty = URL(string: "novpool://oauth?state=s")!
        #expect(throws: OAuthCallbackParser.Failure.missingCode) {
            try OAuthCallbackParser.authorizationCode(from: empty, expectedState: "s")
        }
    }

    // MARK: - Authorized Address

    @Test("Google authorization URL with PKCE and offline access parameters")
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

    @Test("Microsoft authorization URL follows the tenant; Notion does not include PKCE but includes owner")
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

    // MARK: - Arrangement

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

    @Test("Google Authorization: Complete browser callback → Exchange token → Write credentials → Register connector")
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

        // Token exchange request: authorization code + PKCE verifier
        let request = try #require(harness.transport.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=code-1"))
        #expect(body.contains("code_verifier="))

        // Credentials fall into the (memory) Keychain, and the connector registers to the database
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

    @Test("OneDrive Authorization: Tenant and Target Path Written into Configuration")
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
            targetPath: "NovPool/Technology"
        )
        let record = try #require(try await harness.repository.fetch(id: "onedrive"))
        #expect(record.configJSON.contains("contoso"))
        #expect(record.configJSON.contains("NovPool/Technology"))
    }

    @Test("Notion Authorization: Basic authentication switched to long-term token, register using token method")
    func notionFlow() async throws {
        let callback = URL(string: "novpool://oauth?code=code-3&state=fixed-state")!
        let harness = try await makeHarness(
            callback: callback,
            tokenResponse: HTTPPayload(json: #"{"access_token":"ntn_long","workspace_name":"My team"}"#)
        )

        let outcome = try await harness.coordinator.authorizeNotionConnector(
            connectorID: "notion",
            name: "Notion",
            definition: .notion(clientID: "cid"),
            clientID: "cid",
            clientSecret: "secret",
            config: NotionConnector.Config(databaseID: "db-1", titleProperty: "Name")
        )

        #expect(outcome.detail.contains("My team"))
        let request = try #require(harness.transport.requests.first)
        let expectedBasic = Data("cid:secret".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(expectedBasic)")
        #expect(String(decoding: try #require(harness.credentials.secret(for: "notion.token")), as: UTF8.self)
            == "ntn_long")

        let record = try #require(try await harness.repository.fetch(id: "notion"))
        #expect(record.keychainAccountRef == "notion.token")
        #expect(record.configJSON.contains("db-1"))
    }

    @Test("Readable errors are thrown when authorization is canceled, without leaving a half-finished connector.")
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

    @Test("Directly report an error when the client ID is missing, without opening the browser")
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
