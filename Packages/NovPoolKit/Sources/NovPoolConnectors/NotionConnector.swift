import Foundation
import NovPoolCore

/// Notion database (for setting the panel Selectwrite target).
public struct NotionDatabase: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Notion Connector: Write the standardized payload as a Page in the database (properties + native Block Body).
public struct NotionConnector: DestinationConnector {
    public struct Config: Codable, Sendable, Equatable {
        /// Target database ID.
        public var databaseID: String
        /// Title property name (Notion database default is called Name / Name).
        public var titleProperty: String
        /// Optional: Write the source URL or the pre-network disk link into the URL attribute.
        public var urlProperty: String?
        /// Optional: the multi_select attribute name of the write label.
        public var tagsProperty: String?
        /// Optional: The select attribute name for category write.
        public var categoryProperty: String?
        /// Optional: the rich_text attribute name of summary write.
        public var summaryProperty: String?
        /// Whether to write the upstream Link of cross-cloud cascading as a Body paragraph.
        public var includeUpstreamLinkBlock: Bool
        public var apiVersion: String

        public init(
            databaseID: String,
            titleProperty: String = "Name",
            urlProperty: String? = nil,
            tagsProperty: String? = nil,
            categoryProperty: String? = nil,
            summaryProperty: String? = nil,
            includeUpstreamLinkBlock: Bool = true,
            apiVersion: String = "2022-06-28"
        ) {
            self.databaseID = databaseID
            self.titleProperty = titleProperty
            self.urlProperty = urlProperty
            self.tagsProperty = tagsProperty
            self.categoryProperty = categoryProperty
            self.summaryProperty = summaryProperty
            self.includeUpstreamLinkBlock = includeUpstreamLinkBlock
            self.apiVersion = apiVersion
        }

        /// Fault-tolerant parsing: simply writing `databaseID` should also work.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            databaseID = try container.decodeIfPresent(String.self, forKey: .databaseID) ?? ""
            titleProperty = try container.decodeIfPresent(String.self, forKey: .titleProperty) ?? "Name"
            urlProperty = try container.decodeIfPresent(String.self, forKey: .urlProperty)
            tagsProperty = try container.decodeIfPresent(String.self, forKey: .tagsProperty)
            categoryProperty = try container.decodeIfPresent(String.self, forKey: .categoryProperty)
            summaryProperty = try container.decodeIfPresent(String.self, forKey: .summaryProperty)
            includeUpstreamLinkBlock = try container
                .decodeIfPresent(Bool.self, forKey: .includeUpstreamLinkBlock) ?? true
            apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion) ?? "2022-06-28"
        }
    }

    public var connectorType: String { "notion" }

    private let token: String?
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        token: String?,
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://api.notion.com/v1")!
    ) {
        self.token = token
        self.transport = transport
        self.baseURL = baseURL
    }

    public func validateAuthentication(configJSON: Data) async throws -> Bool {
        let config = try decodeConfig(configJSON)
        guard let request = try authorizedRequest(path: "users/me", method: "GET", config: config) else {
            return false
        }
        let payload = try await transport.send(request)
        return (200..<300).contains(payload.statusCode)
    }

    /// List writable databases (for settings panel).
    public func listDatabases(configJSON: Data) async throws -> [NotionDatabase] {
        let config = try decodeConfig(configJSON)
        var body: [String: Any] = ["page_size": 50]
        body["filter"] = ["property": "object", "value": "database"]
        guard let request = try authorizedRequest(
            path: "search",
            method: "POST",
            config: config,
            body: body
        ) else {
            throw NovPoolError.authenticationRequired("notion")
        }
        let payload = try await transport.send(request)
        guard (200..<300).contains(payload.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: payload.body)) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else {
            throw NovPoolError.connectorNotConfigured("Notion list databases failed (HTTP\(payload.statusCode))")
        }
        return results.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let title = (item["title"] as? [[String: Any]])?
                .compactMap { ($0["plain_text"] as? String) }
                .joined() ?? "Untitled database"
            return NotionDatabase(id: id, title: title)
        }
    }

    public func push(payload: NormalizedPayload, configJSON: Data) async throws -> RemoteReceipt {
        let config = try decodeConfig(configJSON)
        guard config.databaseID.isEmpty == false else {
            throw NovPoolError.connectorNotConfigured("Notion target database not configured")
        }
        guard token?.isEmpty == false else {
            throw NovPoolError.authenticationRequired("notion")
        }

        let markdown = payload.markdownBody ?? payload.ocrText ?? ""
        let blocks = NotionBlocks.blocks(
            fromMarkdown: markdown,
            upstreamURL: config.includeUpstreamLinkBlock ? payload.upstreamAssetURL : nil
        )
        let firstBatch = Array(blocks.prefix(NotionBlocks.maxBlocksPerRequest))

        var body: [String: Any] = [
            "parent": ["database_id": config.databaseID],
            "properties": Self.properties(payload: payload, config: config),
        ]
        if !firstBatch.isEmpty { body["children"] = firstBatch }

        guard let request = try authorizedRequest(path: "pages", method: "POST", config: config, body: body) else {
            throw NovPoolError.authenticationRequired("notion")
        }
        let payloadResponse = try await transport.send(request)
        guard (200..<300).contains(payloadResponse.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: payloadResponse.body)) as? [String: Any],
              let pageID = object["id"] as? String else {
            let detail = String(decoding: payloadResponse.body.prefix(300), as: UTF8.self)
            throw NovPoolError.connectorNotConfigured("Notion create page failed (HTTP\(payloadResponse.statusCode)): \(detail)")
        }
        let pageURL = (object["url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://www.notion.so/\(pageID.replacingOccurrences(of: "-", with: ""))")!

        // When the body exceeds 100 blocks, append in batches.
        var remaining = Array(blocks.dropFirst(firstBatch.count))
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(NotionBlocks.maxBlocksPerRequest))
            remaining.removeFirst(batch.count)
            try await appendBlocks(batch, pageID: pageID, config: config)
        }

        return RemoteReceipt(
            connectorID: connectorType,
            remoteItemID: pageID,
            remoteWebURL: pageURL
        )
    }

    // MARK: - Internals

    private func appendBlocks(_ blocks: [[String: Any]], pageID: String, config: Config) async throws {
        guard let request = try authorizedRequest(
            path: "blocks/\(pageID)/children",
            method: "PATCH",
            config: config,
            body: ["children": blocks]
        ) else {
            throw NovPoolError.authenticationRequired("notion")
        }
        let payload = try await transport.send(request)
        guard (200..<300).contains(payload.statusCode) else {
            throw NovPoolError.connectorNotConfigured("Notion append body failed (HTTP\(payload.statusCode))")
        }
    }

    private func authorizedRequest(
        path: String,
        method: String,
        config: Config,
        body: [String: Any]? = nil
    ) throws -> URLRequest? {
        guard let token, !token.isEmpty else { return nil }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.apiVersion, forHTTPHeaderField: "Notion-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func decodeConfig(_ configJSON: Data) throws -> Config {
        do {
            return try JSONDecoder().decode(Config.self, from: configJSON)
        } catch {
            throw NovPoolError.connectorNotConfigured("Notion config parse failed: \(error.localizedDescription)")
        }
    }

    /// Attribute mapping: Title is required, the rest are selectively writable according to user configuration.
    static func properties(payload: NormalizedPayload, config: Config) -> [String: Any] {
        var properties: [String: Any] = [
            config.titleProperty: ["title": NotionBlocks.richText(payload.title)],
        ]
        if let urlProperty = config.urlProperty,
           let url = payload.upstreamAssetURL ?? payload.sourceContext.pageURL {
            properties[urlProperty] = ["url": url.absoluteString]
        }
        if let tagsProperty = config.tagsProperty, !payload.aiTags.isEmpty {
            properties[tagsProperty] = [
                "multi_select": payload.aiTags.map { ["name": String($0.prefix(100))] },
            ]
        }
        if let categoryProperty = config.categoryProperty, let category = payload.aiCategory {
            properties[categoryProperty] = ["select": ["name": String(category.prefix(100))]]
        }
        if let summaryProperty = config.summaryProperty, let summary = payload.aiSummary {
            properties[summaryProperty] = ["rich_text": NotionBlocks.richText(summary)]
        }
        return properties
    }
}
