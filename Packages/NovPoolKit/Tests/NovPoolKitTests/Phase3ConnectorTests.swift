import CoreGraphics
import CryptoKit
import Foundation
@testable import NovPoolConnectors
import NovPoolCore
import NovPoolStorage
import Testing

@Suite("Notion: Markdown → Block Conversion")
struct NotionBlocksTests {
    private func types(_ markdown: String) -> [String] {
        NotionBlocks.blocks(fromMarkdown: markdown).compactMap { $0["type"] as? String }
    }

    @Test("Block-level structures: Heading, List, To-do, Quote, Divider, Code, Image")
    func blockTypes() {
        let markdown = """
        # Heading 1
        ## Heading 2
        ### Heading 3
        #### Heading 4

        Body paragraph.

        - Bullet item
        * Another bullet
        1. Numbered item
        - [x] Done
        - [ ] Todo
        > Quote content
        ---
        ```swift
        let value = 1
        ```
        ![Diagram](https://example.com/a.png)
        """
        #expect(types(markdown) == [
            "heading_1", "heading_2", "heading_3", "heading_3",
            "paragraph",
            "bulleted_list_item", "bulleted_list_item", "numbered_list_item",
            "to_do", "to_do",
            "quote", "divider", "code", "image",
        ])
    }

    @Test("Combine multiple consecutive lines into a single paragraph block")
    func paragraphMerging() {
        let blocks = NotionBlocks.blocks(fromMarkdown: "First line\nSecond line\n\nSecond paragraph")
        #expect(blocks.count == 2)
        let first = (blocks[0]["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]]
        #expect((first?.first?["text"] as? [String: Any])?["content"] as? String == "First line\nSecond line")
    }

    @Test("To-do check status is retained")
    func todoCheckedState() {
        let blocks = NotionBlocks.blocks(fromMarkdown: "- [x] Complete\n- [ ] Incomplete")
        #expect((blocks[0]["to_do"] as? [String: Any])?["checked"] as? Bool == true)
        #expect((blocks[1]["to_do"] as? [String: Any])?["checked"] as? Bool == false)
    }

    @Test("Code language mapping: known reserved, alias normalized, unknown falls to plain text")
    func codeLanguageMapping() {
        #expect(NotionBlocks.notionLanguage("swift") == "swift")
        #expect(NotionBlocks.notionLanguage("js") == "javascript")
        #expect(NotionBlocks.notionLanguage("yml") == "yaml")
        #expect(NotionBlocks.notionLanguage("brainfuck") == "plain text")

        let blocks = NotionBlocks.blocks(fromMarkdown: "```js\nlet a = 1\n```")
        #expect((blocks[0]["code"] as? [String: Any])?["language"] as? String == "javascript")
    }

    @Test("Inline formats: bold, inline code, link annotation")
    func inlineAnnotations() {
        let rich = NotionBlocks.richText("Ordinary**Bold** and`code` and[Link](https://example.com/x)")
        let contents = rich.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }
        #expect(contents == ["Ordinary", "Bold", " and", "code", " and", "Link"])

        let bold = rich.first { ($0["text"] as? [String: Any])?["content"] as? String == "Bold" }
        #expect((bold?["annotations"] as? [String: Any])?["bold"] as? Bool == true)

        let code = rich.first { ($0["text"] as? [String: Any])?["content"] as? String == "code" }
        #expect((code?["annotations"] as? [String: Any])?["code"] as? Bool == true)

        let link = rich.first { ($0["text"] as? [String: Any])?["content"] as? String == "Link" }
        #expect((link?["text"] as? [String: Any])?["link"] as? [String: String] == ["url": "https://example.com/x"])
    }

    @Test("Text longer than 2000 characters will be split into multiple rich_text objects")
    func richTextChunking() {
        let long = String(repeating: "x", count: 4500)
        let rich = NotionBlocks.richText(long)
        #expect(rich.count == 3)
        #expect(rich.allSatisfy {
            let content = ($0["text"] as? [String: Any])?["content"] as? String ?? ""
            return content.count <= NotionBlocks.maxRichTextCharacters
        })
    }

    @Test("Cross-cloud Cascade: Upstream Link is appended to the Body as a clickable paragraph")
    func upstreamLinkBlock() throws {
        let url = try #require(URL(string: "https://drive.google.com/file/d/ABC/view"))
        let blocks = NotionBlocks.blocks(fromMarkdown: "Body", upstreamURL: url)
        #expect(blocks.count == 2)
        #expect(blocks.last?["type"] as? String == "paragraph")
        let rich = (blocks.last?["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]]
        #expect((rich?.first?["text"] as? [String: Any])?["link"] as? [String: String]
            == ["url": url.absoluteString])

        #expect(NotionBlocks.blocks(fromMarkdown: "Body", upstreamURL: nil).count == 1)
    }
}

@Suite("Notion Connector: Request Construction and Response Parsing")
struct NotionConnectorTests {
    private let config = NotionConnector.Config(
        databaseID: "db-123",
        titleProperty: "Name",
        urlProperty: "Source",
        tagsProperty: "Label",
        categoryProperty: "Classification",
        summaryProperty: "Summary"
    )

    private func makePayload(upstream: URL? = nil) -> NormalizedPayload {
        NormalizedPayload(
            contentType: .documentPDF,
            title: "Quarterly report",
            markdownBody: "# Title\n\nBodyContent.",
            aiSummary: "A one-sentence summary",
            aiCategory: "Technology",
            aiTags: ["Report", "Finance"],
            sourceContext: SourceContext(
                appBundleID: "com.apple.finder",
                pageURL: URL(string: "https://example.com/src")
            ),
            upstreamAssetURL: upstream
        )
    }

    @Test("Create record request: with authentication header and Notion-Version, attributes and body mapped according to configuration")
    func pushBuildsRequest() async throws {
        let transport = StubTransport(responses: [
            HTTPPayload(json: #"{"id":"page-1","url":"https://notion.so/page-1"}"#),
        ])
        let connector = NotionConnector(token: "secret_token", transport: transport)
        let receipt = try await connector.push(
            payload: makePayload(),
            configJSON: try JSONEncoder().encode(config)
        )

        #expect(receipt.remoteItemID == "page-1")
        #expect(receipt.remoteWebURL.absoluteString == "https://notion.so/page-1")

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.notion.com/v1/pages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret_token")
        #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2022-06-28")

        let body = try #require(request.httpBody)
        let json = try #require((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
        #expect((json["parent"] as? [String: Any])?["database_id"] as? String == "db-123")

        let properties = try #require(json["properties"] as? [String: Any])
        #expect((properties["Name"] as? [String: Any])?["title"] != nil)
        #expect((properties["Source"] as? [String: Any])?["url"] as? String == "https://example.com/src")
        let tags = (properties["Label"] as? [String: Any])?["multi_select"] as? [[String: String]]
        #expect(tags?.compactMap { $0["name"] } == ["Report", "Finance"])
        #expect((properties["Classification"] as? [String: Any])?["select"] as? [String: String] == ["name": "Technology"])
        #expect((properties["Summary"] as? [String: Any])?["rich_text"] != nil)

        let children = try #require(json["children"] as? [[String: Any]])
        #expect(children.first?["type"] as? String == "heading_1")
    }

    @Test("Upstream cascading Link takes precedence over source URL write URL attributes")
    func upstreamLinkTakesPrecedence() async throws {
        let transport = StubTransport(responses: [HTTPPayload(json: #"{"id":"p","url":"https://n/p"}"#)])
        let connector = NotionConnector(token: "t", transport: transport)
        _ = try await connector.push(
            payload: makePayload(upstream: URL(string: "https://drive.google.com/file/d/XYZ/view")),
            configJSON: try JSONEncoder().encode(config)
        )
        let body = try #require(transport.requests.first?.httpBody)
        let json = try #require((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
        let properties = try #require(json["properties"] as? [String: Any])
        #expect((properties["Source"] as? [String: Any])?["url"] as? String
            == "https://drive.google.com/file/d/XYZ/view")
    }

    @Test("When the body exceeds 100 blocks, append in batches")
    func appendsRemainingBlocks() async throws {
        let markdown = (1...150).map { "Paragraph\($0)" }.joined(separator: "\n\n")
        let transport = StubTransport(responses: [
            HTTPPayload(json: #"{"id":"page-9","url":"https://notion.so/page-9"}"#),
            HTTPPayload(json: #"{"results":[]}"#),
        ])
        let connector = NotionConnector(token: "t", transport: transport)
        var payload = makePayload()
        payload.markdownBody = markdown
        _ = try await connector.push(payload: payload, configJSON: try JSONEncoder().encode(config))

        #expect(transport.requests.count == 2)
        let append = try #require(transport.requests.last)
        #expect(append.url?.absoluteString == "https://api.notion.com/v1/blocks/page-9/children")
        #expect(append.httpMethod == "PATCH")
        let appendBody = try #require(append.httpBody)
        let json = try #require((try? JSONSerialization.jsonObject(with: appendBody)) as? [String: Any])
        #expect((json["children"] as? [[String: Any]])?.count == 50)
    }

    @Test("Provide clear errors when token or database configuration is missing")
    func configurationErrors() async throws {
        let transport = StubTransport(responses: [])
        let noToken = NotionConnector(token: nil, transport: transport)
        await #expect(throws: NovPoolError.self) {
            _ = try await noToken.push(payload: makePayload(), configJSON: try JSONEncoder().encode(config))
        }
        #expect(try await noToken.validateAuthentication(configJSON: try JSONEncoder().encode(config)) == false)

        let noDatabase = NotionConnector(token: "t", transport: transport)
        await #expect(throws: NovPoolError.self) {
            _ = try await noDatabase.push(
                payload: makePayload(),
                configJSON: try JSONEncoder().encode(NotionConnector.Config(databaseID: ""))
            )
        }
    }

    @Test("List the databases that can be written to")
    func listDatabases() async throws {
        let response = #"{"results":[{"id":"db-1","title":[{"plain_text":"Tech library"}]},{"id":"db-2","title":[{"plain_text":"Reading library"}]}]}"#
        let transport = StubTransport(responses: [HTTPPayload(json: response)])
        let connector = NotionConnector(token: "t", transport: transport)
        let databases = try await connector.listDatabases(configJSON: try JSONEncoder().encode(config))
        #expect(databases == [
            NotionDatabase(id: "db-1", title: "Tech library"),
            NotionDatabase(id: "db-2", title: "Reading library"),
        ])
    }
}

@Suite("Cloud Drive Connector: Upload Path and Receipt")
struct CloudDriveConnectorTests {
    private func credentials(_ provider: OAuthProviderKind) -> OAuthCredentials {
        OAuthCredentials(
            provider: provider,
            clientID: "client-id",
            clientSecret: "client-secret",
            refreshToken: "refresh-token",
            tenant: "common"
        )
    }

    private func tokenResponse(_ token: String = "access-token") -> HTTPPayload {
        HTTPPayload(json: #"{"access_token":"\#(token)","expires_in":3600}"#)
    }

    private func makePayload(fileURL: URL?, title: String = "Report") -> NormalizedPayload {
        NormalizedPayload(
            contentType: fileURL == nil ? .webLink : .documentPDF,
            title: title,
            markdownBody: "# Body",
            aiCategory: "Technology",
            localStagedURL: fileURL,
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )
    }

    private func stagedFile(_ directory: URL, name: String, bytes: Int) throws -> URL {
        let url = directory.appending(path: name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: - Google Drive

    @Test("Drive small File to multipart, get the webViewLink for receipt")
    func driveMultipartUpload() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("drive")
        let file = try stagedFile(directory, name: "report.pdf", bytes: 2_048)
        let transport = StubTransport(responses: [
            tokenResponse(),
            HTTPPayload(json: #"{"id":"file-1","webViewLink":"https://drive.google.com/file/d/file-1/view"}"#),
        ])
        let connector = GoogleDriveAPIConnector(credentials: credentials(.google), transport: transport)
        let receipt = try await connector.push(
            payload: makePayload(fileURL: file),
            configJSON: try JSONSerialization.data(withJSONObject: ["folderID": "folder-9"])
        )

        #expect(receipt.remoteItemID == "file-1")
        #expect(receipt.remoteWebURL.absoluteString == "https://drive.google.com/file/d/file-1/view")

        let upload = try #require(transport.requests.last)
        #expect(upload.url?.absoluteString.contains("uploadType=multipart") == true)
        #expect(upload.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        let contentType = try #require(upload.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/related; boundary="))

        let body = try #require(upload.httpBody)
        #expect(body.count > 2_048)
        let text = String(decoding: body.prefix(400), as: UTF8.self)
        #expect(text.contains("\"name\""))
        // The file name is generated from the naming template ({Category}/{YYYY}-{MM}/{Title}.{ext}), taking the last segment as the cloud file name.
        #expect(text.contains("Report.pdf"))
        #expect(text.contains("folder-9"))
        #expect(String(decoding: body.suffix(120), as: UTF8.self).contains("--") )
    }

    @Test("Drive large files resumable: create a session first, then PUT to the session URL")
    func driveResumableUpload() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("drive-big")
        let file = try stagedFile(directory, name: "big.pdf", bytes: GoogleDriveAPIConnector.multipartLimit + 1)
        let transport = StubTransport(responses: [
            tokenResponse(),
            HTTPPayload(
                statusCode: 200,
                headers: ["Location": "https://upload.example.com/session-1"],
                body: Data()
            ),
            HTTPPayload(json: #"{"id":"file-2","webViewLink":"https://drive.google.com/file/d/file-2/view"}"#),
        ])
        let connector = GoogleDriveAPIConnector(credentials: credentials(.google), transport: transport)
        let receipt = try await connector.push(
            payload: makePayload(fileURL: file),
            configJSON: Data("{}".utf8)
        )

        #expect(receipt.remoteItemID == "file-2")
        #expect(transport.requests.count == 3)
        let session = transport.requests[1]
        #expect(session.url?.absoluteString.contains("uploadType=resumable") == true)
        #expect(session.value(forHTTPHeaderField: "X-Upload-Content-Type") == "application/pdf")
        #expect(session.value(forHTTPHeaderField: "X-Upload-Content-Length") == String(fileByteCount(file)))

        let put = transport.requests[2]
        #expect(put.url?.absoluteString == "https://upload.example.com/session-1")
        #expect(put.httpMethod == "PUT")
    }

    private func fileByteCount(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size]) as? Int) ?? 0
    }

    @Test("Drive throws a need for authorization when credentials are missing")
    func driveRequiresCredentials() async throws {
        let connector = GoogleDriveAPIConnector(credentials: nil, transport: StubTransport(responses: []))
        await #expect(throws: NovPoolError.self) {
            _ = try await connector.push(payload: makePayload(fileURL: nil), configJSON: Data("{}".utf8))
        }
        #expect(try await connector.validateAuthentication(configJSON: Data("{}".utf8)) == false)
    }

    // MARK: - OneDrive

    @Test("OneDrive small file directly PUT content, receipt obtains webUrl")
    func oneDriveSimpleUpload() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("onedrive")
        let file = try stagedFile(directory, name: "note.md", bytes: 1_024)
        let transport = StubTransport(responses: [
            tokenResponse(),
            HTTPPayload(json: #"{"id":"item-1","webUrl":"https://onedrive.live.com/?id=item-1"}"#),
        ])
        let connector = OneDriveAPIConnector(credentials: credentials(.microsoft), transport: transport)
        let receipt = try await connector.push(
            payload: makePayload(fileURL: file),
            configJSON: try JSONSerialization.data(withJSONObject: ["folderPath": "NovPool/Technology"])
        )

        #expect(receipt.remoteItemID == "item-1")
        let upload = try #require(transport.requests.last)
        let expectedPath = OneDriveAPIConnector.encodePath("NovPool/Technology/Report.md")
        #expect(upload.url?.absoluteString
            == "https://graph.microsoft.com/v1.0/me/drive/root:/\(expectedPath):/content")
        #expect(upload.httpMethod == "PUT")
        #expect(upload.value(forHTTPHeaderField: "Content-Type") == "text/markdown")
    }

    @Test("OneDrive large file chunked upload, Content-Range and chunk size comply with Graph requirements")
    func oneDriveChunkedUpload() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("onedrive-big")
        let totalBytes = OneDriveAPIConnector.simpleUploadLimit + 4 * 1024 * 1024
        let file = try stagedFile(directory, name: "big.pdf", bytes: totalBytes)
        let transport = StubTransport(responses: [
            tokenResponse(),
            HTTPPayload(json: #"{"uploadUrl":"https://upload.example.com/graph-session"}"#),
            HTTPPayload(json: #"{"nextExpectedRanges":["5242880"]}"#),
            HTTPPayload(json: #"{"id":"item-2","webUrl":"https://onedrive.live.com/?id=item-2"}"#),
        ])
        let connector = OneDriveAPIConnector(credentials: credentials(.microsoft), transport: transport)
        let receipt = try await connector.push(
            payload: makePayload(fileURL: file),
            configJSON: Data("{}".utf8)
        )

        #expect(receipt.remoteItemID == "item-2")
        let session = transport.requests[1]
        #expect(session.url?.absoluteString.hasSuffix(":/createUploadSession") == true)
        #expect(session.httpMethod == "POST")

        let chunks = transport.requests.dropFirst(2)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.httpMethod == "PUT" })
        #expect(chunks.allSatisfy { $0.url?.absoluteString == "https://upload.example.com/graph-session" })
        #expect(chunks.first?.value(forHTTPHeaderField: "Content-Range")
            == "bytes 0-\(OneDriveAPIConnector.chunkSize - 1)/\(totalBytes)")
        #expect(chunks.last?.value(forHTTPHeaderField: "Content-Range")
            == "bytes \(OneDriveAPIConnector.chunkSize)-\(totalBytes - 1)/\(totalBytes)")
        #expect(OneDriveAPIConnector.chunkSize % OneDriveAPIConnector.uploadChunkUnit == 0)
    }

    @Test("OneDrive path cleaning: remove traversal and encode special characters")
    func oneDrivePathHandling() {
        #expect(OneDriveAPIConnector.remotePath(folderPath: nil, fileName: "a.md") == "a.md")
        #expect(OneDriveAPIConnector.remotePath(folderPath: "  ", fileName: "a.md") == "a.md")
        #expect(OneDriveAPIConnector.remotePath(folderPath: "../etc/passwd", fileName: "a.md") == "etc/passwd/a.md")
        let encoded = OneDriveAPIConnector.encodePath("NovPool/Technical Report.md")
        // Slashes must be kept as hierarchy separators, and spaces must be encoded
        #expect(encoded.contains("NovPool/"))
        #expect(encoded.filter { $0 == "/" }.count == 1)
        #expect(!encoded.contains(" "))
    }

    @Test("OneDrive throws 'authorization required' when credentials are missing")
    func oneDriveRequiresCredentials() async throws {
        let connector = OneDriveAPIConnector(credentials: nil, transport: StubTransport(responses: []))
        await #expect(throws: NovPoolError.self) {
            _ = try await connector.push(payload: makePayload(fileURL: nil), configJSON: Data("{}".utf8))
        }
    }

    @Test("MIME type mapping overrides common archive formats")
    func mimeTypes() {
        #expect(MimeType.forExtension("png") == "image/png")
        #expect(MimeType.forExtension("PDF") == "application/pdf")
        #expect(MimeType.forExtension("md") == "text/markdown")
        #expect(MimeType.forExtension("xlsx").contains("spreadsheetml"))
        #expect(MimeType.forExtension("unknown") == "application/octet-stream")
    }
}

@Suite("OAuth: PKCE and Token Refresh")
struct OAuthTests {
    private let credentials = OAuthCredentials(
        provider: .google,
        clientID: "client-id",
        clientSecret: "client-secret",
        refreshToken: "refresh-token"
    )

    @Test("PKCE: verifier is a URL-safe character, challenge is S256's base64url")
    func pkceDerivation() {
        let verifier = PKCE.codeVerifier()
        #expect(verifier.count >= 43)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })

        let challenge = PKCE.codeChallenge(for: verifier)
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))

        // Align with the local SHA256 result to confirm that the algorithm is S256 and not plaintext.
        let expected = PKCE.base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        #expect(challenge == expected)
    }

    @Test("Refresh token request: form parameters are correct, parsing access_token")
    func refreshTokenRequest() async throws {
        let transport = StubTransport(responses: [HTTPPayload(json: #"{"access_token":"fresh-token"}"#)])
        let service = OAuthTokenService(transport: transport)
        let token = try await service.accessToken(credentials: credentials)
        #expect(token == "fresh-token")

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("client_id=client-id"))
        #expect(body.contains("refresh_token=refresh-token"))
    }

    @Test("Microsoft token endpoint includes tenant, and the request contains scope")
    func microsoftTokenEndpoint() async throws {
        let transport = StubTransport(responses: [HTTPPayload(json: #"{"access_token":"graph-token"}"#)])
        let service = OAuthTokenService(transport: transport)
        var microsoft = credentials
        microsoft.provider = .microsoft
        microsoft.tenant = "contoso"
        _ = try await service.accessToken(credentials: microsoft)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://login.microsoftonline.com/contoso/oauth2/v2.0/token")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("scope="))
    }

    @Test("Throw 'authorization required' when there is no refresh token or the server reports an error")
    func refreshFailures() async throws {
        let empty = OAuthCredentials(provider: .google, clientID: "c", refreshToken: "")
        let service = OAuthTokenService(transport: StubTransport(responses: []))
        await #expect(throws: NovPoolError.self) {
            _ = try await service.accessToken(credentials: empty)
        }

        let failing = OAuthTokenService(transport: StubTransport(responses: [
            HTTPPayload(json: #"{"error":"invalid_grant"}"#, statusCode: 400),
        ]))
        await #expect(throws: NovPoolError.self) {
            _ = try await failing.accessToken(credentials: credentials)
        }
    }

    @Test("The authorization address includes PKCE parameters and offline access scope")
    func authorizationURL() throws {
        let url = OAuthAuthorizationRequest.url(
            credentials: credentials,
            codeChallenge: "challenge-value",
            redirectURI: "novpool://oauth",
            state: "state-1"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(components.host == "accounts.google.com")
        #expect(items["client_id"] == "client-id")
        #expect(items["code_challenge"] == "challenge-value")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["redirect_uri"] == "novpool://oauth")
        #expect(items["access_type"] == "offline")
        #expect(items["scope"]?.contains("drive.file") == true)
    }
}
