import Foundation
import NovPoolCore
import Testing

@Suite("Routing Rule Evaluation")
struct RouteEvaluatorTests {
    private let notionRule = RouteRule(
        id: "r-notion",
        name: "Technical content into Notion",
        priority: 10,
        categories: ["Technology"],
        targetConnectorIDs: ["notion"]
    )
    private let pdfRule = RouteRule(
        id: "r-pdf",
        name: "PDF Advanced Cloud Drive",
        priority: 5,
        contentTypes: [.documentPDF],
        targetConnectorIDs: ["gdrive", "notion"]
    )
    private let keywordRule = RouteRule(
        id: "r-keyword",
        name: "Including paper keywords",
        priority: 1,
        keywords: ["Thesis", "paper"],
        targetConnectorIDs: ["obsidian"]
    )

    @Test("Sector forced routing takes precedence over all rules")
    func forcedZoneWins() {
        let evaluator = RouteEvaluator(
            rules: [notionRule, pdfRule],
            defaultConnectorIDs: ["obsidian"]
        )
        let decision = evaluator.evaluate(
            payload: TestSupport.samplePayload(contentType: .documentPDF, category: "Technology"),
            forcedZone: DropZone(id: "gdrive", title: "Google Drive", systemImage: "cloud", connectorID: "gdrive")
        )
        #expect(decision.connectorIDs == ["gdrive"])
        #expect(decision.reason == .sectorForced(zoneID: "gdrive"))
    }

    @Test("Select the matching rule with the highest priority")
    func highestPriorityRuleWins() {
        let evaluator = RouteEvaluator(rules: [pdfRule, notionRule, keywordRule])
        let decision = evaluator.evaluate(
            payload: TestSupport.samplePayload(contentType: .documentPDF, category: "Technology")
        )
        #expect(decision.connectorIDs == ["notion"])
        #expect(decision.reason == .smartRouteRule(ruleID: "r-notion", ruleName: "Technical content into Notion"))
    }

    @Test("Keyword matches the Body, and it is case-insensitive")
    func keywordMatching() {
        let evaluator = RouteEvaluator(rules: [notionRule, keywordRule])
        let decision = evaluator.evaluate(
            payload: TestSupport.samplePayload(body: "This paper discusses edge-side inference")
        )
        #expect(decision.connectorIDs == ["obsidian"])
    }

    @Test("When there is no regular hit, it falls back to the user's default target")
    func fallback() {
        let evaluator = RouteEvaluator(rules: [notionRule], defaultConnectorIDs: ["obsidian"])
        let decision = evaluator.evaluate(payload: TestSupport.samplePayload(category: "Life"))
        #expect(decision.connectorIDs == ["obsidian"])
        #expect(decision.reason == .fallback)
    }

    @Test("Disabled rules and empty target rules do not participate in matching")
    func disabledAndEmptyRulesIgnored() {
        var disabled = notionRule
        disabled.isEnabled = false
        let empty = RouteRule(id: "r-empty", name: "Empty target", priority: 99, targetConnectorIDs: [])
        let evaluator = RouteEvaluator(rules: [disabled, empty], defaultConnectorIDs: ["local"])
        let decision = evaluator.evaluate(payload: TestSupport.samplePayload(category: "Technology"))
        #expect(decision.reason == .fallback)
    }

    @Test("Multiple conditions are combined with AND")
    func conditionsAreConjunctive() {
        let rule = RouteRule(
            id: "r-both",
            name: "Chrome the technical content inside",
            categories: ["Technology"],
            sourceAppBundleIDs: ["com.google.Chrome"],
            targetConnectorIDs: ["notion"]
        )
        let evaluator = RouteEvaluator(rules: [rule], defaultConnectorIDs: ["local"])
        let matching = evaluator.evaluate(
            payload: TestSupport.samplePayload(category: "Technology", sourceApp: "com.google.Chrome")
        )
        #expect(matching.connectorIDs == ["notion"])

        let mismatching = evaluator.evaluate(
            payload: TestSupport.samplePayload(category: "Technology", sourceApp: "com.apple.Safari")
        )
        #expect(mismatching.reason == .fallback)
    }
}
