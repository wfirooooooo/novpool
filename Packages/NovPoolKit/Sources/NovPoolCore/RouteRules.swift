import Foundation

/// Routing rule: Map payload characteristics to a set of target connectors.
public struct RouteRule: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    /// The larger the value, the higher the matching priority; ties are stably sorted by `id` to ensure reproducible routing results.
    public var priority: Int
    public var isEnabled: Bool

    // Matching conditions (all non-empty conditions are connected by 'and')
    public var contentTypes: [ContentType]
    public var categories: [String]
    public var tags: [String]
    public var sourceAppBundleIDs: [String]
    /// Case-insensitive substring matching for Title / Body / OCR Text.
    public var keywords: [String]

    public var targetConnectorIDs: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        priority: Int = 0,
        isEnabled: Bool = true,
        contentTypes: [ContentType] = [],
        categories: [String] = [],
        tags: [String] = [],
        sourceAppBundleIDs: [String] = [],
        keywords: [String] = [],
        targetConnectorIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.priority = priority
        self.isEnabled = isEnabled
        self.contentTypes = contentTypes
        self.categories = categories
        self.tags = tags
        self.sourceAppBundleIDs = sourceAppBundleIDs
        self.keywords = keywords
        self.targetConnectorIDs = targetConnectorIDs
    }

    public func matches(_ payload: NormalizedPayload) -> Bool {
        guard isEnabled else { return false }
        guard !targetConnectorIDs.isEmpty else { return false }

        if !contentTypes.isEmpty, !contentTypes.contains(payload.contentType) { return false }
        if !categories.isEmpty {
            guard let category = payload.aiCategory, categories.contains(category) else { return false }
        }
        if !tags.isEmpty {
            let payloadTags = Set(payload.aiTags.map(Self.normalize))
            guard !payloadTags.isDisjoint(with: tags.map(Self.normalize)) else { return false }
        }
        if !sourceAppBundleIDs.isEmpty,
           !sourceAppBundleIDs.contains(payload.sourceContext.appBundleID) {
            return false
        }
        if !keywords.isEmpty {
            let haystack = [payload.title, payload.markdownBody, payload.ocrText, payload.aiSummary]
                .compactMap { $0 }
                .joined(separator: "\n")
                .lowercased()
            guard keywords.contains(where: { haystack.contains($0.lowercased()) }) else { return false }
        }
        return true
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Routing decisions and their basis, making it easier to explain in the settings panel 'why this route was taken'.
public enum RouteReason: Sendable, Equatable {
    case sectorForced(zoneID: String)
    case smartRouteRule(ruleID: String, ruleName: String)
    case fallback
}

public struct RouteDecision: Sendable, Equatable {
    public var connectorIDs: [String]
    public var reason: RouteReason

    public init(connectorIDs: [String], reason: RouteReason) {
        self.connectorIDs = connectorIDs
        self.reason = reason
    }
}

/// Sector forced routing / rule-matching routing evaluator (AI Semantic Routing will be integrated after Phase 2).
public struct RouteEvaluator: Sendable {
    public var rules: [RouteRule]
    /// Intelligent routing fallback connector (user-configured default archive target).
    public var defaultConnectorIDs: [String]

    public init(rules: [RouteRule] = [], defaultConnectorIDs: [String] = []) {
        self.rules = rules
        self.defaultConnectorIDs = defaultConnectorIDs
    }

    public func evaluate(
        payload: NormalizedPayload,
        forcedZone: DropZone? = nil
    ) -> RouteDecision {
        if let zone = forcedZone, let connectorID = zone.connectorID {
            return RouteDecision(connectorIDs: [connectorID], reason: .sectorForced(zoneID: zone.id))
        }

        let matched = rules
            .filter { $0.matches(payload) }
            .sorted { lhs, rhs in
                lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority > rhs.priority
            }
            .first

        if let rule = matched {
            return RouteDecision(
                connectorIDs: rule.targetConnectorIDs,
                reason: .smartRouteRule(ruleID: rule.id, ruleName: rule.name)
            )
        }

        return RouteDecision(connectorIDs: defaultConnectorIDs, reason: .fallback)
    }
}
