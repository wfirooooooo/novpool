import Foundation
import NovPoolCore
import Testing

@Suite("路由规则评估")
struct RouteEvaluatorTests {
    private let notionRule = RouteRule(
        id: "r-notion",
        name: "技术内容进 Notion",
        priority: 10,
        categories: ["技术"],
        targetConnectorIDs: ["notion"]
    )
    private let pdfRule = RouteRule(
        id: "r-pdf",
        name: "PDF 先进网盘",
        priority: 5,
        contentTypes: [.documentPDF],
        targetConnectorIDs: ["gdrive", "notion"]
    )
    private let keywordRule = RouteRule(
        id: "r-keyword",
        name: "含论文关键词",
        priority: 1,
        keywords: ["论文", "paper"],
        targetConnectorIDs: ["obsidian"]
    )

    @Test("扇区强制路由优先于一切规则")
    func forcedZoneWins() {
        let evaluator = RouteEvaluator(
            rules: [notionRule, pdfRule],
            defaultConnectorIDs: ["obsidian"]
        )
        let decision = evaluator.evaluate(
            payload: TestSupport.samplePayload(contentType: .documentPDF, category: "技术"),
            forcedZone: DropZone(id: "gdrive", title: "Google Drive", systemImage: "cloud", connectorID: "gdrive")
        )
        #expect(decision.connectorIDs == ["gdrive"])
        #expect(decision.reason == .sectorForced(zoneID: "gdrive"))
    }

    @Test("按优先级选择最高的匹配规则")
    func highestPriorityRuleWins() {
        let evaluator = RouteEvaluator(rules: [pdfRule, notionRule, keywordRule])
        let decision = evaluator.evaluate(
            payload: TestSupport.samplePayload(contentType: .documentPDF, category: "技术")
        )
        #expect(decision.connectorIDs == ["notion"])
        #expect(decision.reason == .smartRouteRule(ruleID: "r-notion", ruleName: "技术内容进 Notion"))
    }

    @Test("关键词规则匹配正文，且大小写不敏感")
    func keywordMatching() {
        let evaluator = RouteEvaluator(rules: [notionRule, keywordRule])
        let decision = evaluator.evaluate(
            payload: TestSupport.samplePayload(body: "这篇 Paper 讨论了端侧推理")
        )
        #expect(decision.connectorIDs == ["obsidian"])
    }

    @Test("无规则命中时回落到用户默认目标")
    func fallback() {
        let evaluator = RouteEvaluator(rules: [notionRule], defaultConnectorIDs: ["obsidian"])
        let decision = evaluator.evaluate(payload: TestSupport.samplePayload(category: "生活"))
        #expect(decision.connectorIDs == ["obsidian"])
        #expect(decision.reason == .fallback)
    }

    @Test("禁用规则与空目标规则不参与匹配")
    func disabledAndEmptyRulesIgnored() {
        var disabled = notionRule
        disabled.isEnabled = false
        let empty = RouteRule(id: "r-empty", name: "空目标", priority: 99, targetConnectorIDs: [])
        let evaluator = RouteEvaluator(rules: [disabled, empty], defaultConnectorIDs: ["local"])
        let decision = evaluator.evaluate(payload: TestSupport.samplePayload(category: "技术"))
        #expect(decision.reason == .fallback)
    }

    @Test("多条件之间是「与」关系")
    func conditionsAreConjunctive() {
        let rule = RouteRule(
            id: "r-both",
            name: "Chrome 里的技术内容",
            categories: ["技术"],
            sourceAppBundleIDs: ["com.google.Chrome"],
            targetConnectorIDs: ["notion"]
        )
        let evaluator = RouteEvaluator(rules: [rule], defaultConnectorIDs: ["local"])
        let matching = evaluator.evaluate(
            payload: TestSupport.samplePayload(category: "技术", sourceApp: "com.google.Chrome")
        )
        #expect(matching.connectorIDs == ["notion"])

        let mismatching = evaluator.evaluate(
            payload: TestSupport.samplePayload(category: "技术", sourceApp: "com.apple.Safari")
        )
        #expect(mismatching.reason == .fallback)
    }
}
