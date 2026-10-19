import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolSystemBridge

@Suite("Cross-item digest")
struct DigestTests {
    private let sources = [
        DigestSource(id: UUID(), title: "Local models", summary: "Running llama.cpp offline."),
        DigestSource(id: UUID(), title: "Search design", summary: "Hybrid FTS and vector recall."),
    ]

    @Test("Limits default to 30 and allow 10–50")
    func limits() {
        #expect(DigestLimits.defaultMaxItems == 30)
        #expect(DigestLimits.clamp(1) == 10)
        #expect(DigestLimits.clamp(30) == 30)
        #expect(DigestLimits.clamp(99) == 50)
    }

    @Test("Prompt concatenates summaries and only falls back to body excerpts")
    func promptUsesSummaries() {
        let items = [
            DigestSource(id: UUID(), title: "A", summary: "Useful summary", bodyExcerpt: "Full body A"),
            DigestSource(id: UUID(), title: "B", summary: nil, bodyExcerpt: "Fallback body B"),
            DigestSource(id: UUID(), title: "C"),
        ]
        let prompt = DigestPrompt.userPrompt(sources: items)
        #expect(prompt.contains("Summary: Useful summary"))
        #expect(!prompt.contains("Full body A"))
        #expect(prompt.contains("Excerpt: Fallback body B"))
        #expect(prompt.contains("Summary: (none available)"))
    }

    @Test("Prompt respects the character budget with a visible notice")
    func promptBudget() {
        let items = [DigestSource(id: UUID(), title: "Long", summary: String(repeating: "word ", count: 100))]
        let prompt = DigestPrompt.userPrompt(sources: items, maxInputCharacters: 120)
        #expect(prompt.count <= 180)
        #expect(prompt.contains("shortened to fit the context"))
    }

    @Test("Parser builds a draft and cites every source")
    func parserBuildsDraft() throws {
        let raw = """
        ```json
        {"title":"Offline knowledge","overview":"These items cover local AI and search.",
         "keyPoints":["Runs offline","Hybrid recall"],"openQuestions":["How to sync?"]}
        ```
        """
        let draft = try #require(DigestParser.parse(raw, sources: sources))
        #expect(draft.title == "Offline knowledge")
        #expect(draft.overview == "These items cover local AI and search.")
        #expect(draft.keyPoints == ["Runs offline", "Hybrid recall"])
        #expect(draft.openQuestions == ["How to sync?"])
        #expect(draft.citations.map(\.sourceID) == sources.map(\.id))
        #expect(draft.markdownBody.contains("## Key points"))
        #expect(draft.markdownBody.contains("## Sources"))
        #expect(draft.markdownBody.contains("1. Local models"))
    }

    @Test("Parser rejects output without a title or body")
    func parserRejectsEmpty() {
        #expect(DigestParser.parse(#"{"openQuestions":["x"]}"#, sources: sources) == nil)
        #expect(DigestParser.parse("not json", sources: sources) == nil)
    }

    @Test("Service uses the configured completer and returns a draft")
    func serviceGeneratesDigest() async throws {
        let completer = FakeCompleter(
            output: #"{"title":"Offline stack","overview":"Local models plus hybrid search.","keyPoints":["One","Two"],"openQuestions":[]}"#
        )
        let service = AIEnhancementService(completer: completer, embedder: nil)
        let outcome = await service.digest(sources)
        guard case .success(let draft) = outcome else {
            Issue.record("Expected digest success")
            return
        }
        #expect(draft.title == "Offline stack")
        #expect(draft.citations.count == 2)
        #expect(await completer.calls == 1)
    }

    @Test("Service failures carry a readable reason")
    func serviceFailure() async {
        let service = AIEnhancementService(completer: nil, embedder: nil)
        if case .failure(let reason) = await service.digest(sources) {
            #expect(reason.contains("No usable chat model configured"))
        } else {
            Issue.record("Expected failure when no model is configured")
        }

        let failing = AIEnhancementService(
            completer: FakeCompleter(output: "", shouldFail: true),
            embedder: nil
        )
        if case .failure(let reason) = await failing.digest(sources) {
            #expect(reason.contains("Model request failed"))
        } else {
            Issue.record("Expected failure when the model request fails")
        }
    }

    @Test("Saved digest round-trips citations and stays full-text searchable")
    func savedDigestRoundTrip() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("digest")
        let database = try NovPoolDatabase(path: directory.appending(path: "db.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        let repository = KnowledgeRepository(database: database)

        let draft = DigestDraft(
            title: "Offline knowledge stack",
            overview: "Local models plus hybrid retrieval.",
            keyPoints: ["Runs offline"],
            citations: sources.map { DigestCitation(sourceID: $0.id, title: $0.title) }
        )
        let record = draft.makeRecord()
        try await repository.insert(record)

        let fetched = try #require(try await repository.fetch(id: record.id))
        #expect(fetched.contentType == .digest)
        #expect(fetched.digestSourceIDs == sources.map(\.id))
        #expect(fetched.title == "Offline knowledge stack")

        let hits = try await repository.searchFullText("hybrid retrieval")
        #expect(hits.map(\.id) == [record.id])
    }
}
