import AppKit
import Foundation
import NovPoolCore
import NovPoolStorage
import NovPoolSystemBridge
import SwiftUI
import Testing
@testable import NovPoolUI

/// View evaluation regression: SwiftUI evaluates these closures when rendering in the real window,
/// Once a closure contains access that requires isolation checks at runtime, it has crashed under release.
/// Here, all three states of 'silent / expanded / highlighted' are evaluated, at least maintaining the baseline that 'the view can be evaluated'.
@Suite("View Evaluation Probe")
@MainActor
struct ViewRenderProbeTests {
    @Test("Both the silent state and the expanded state can be evaluated")
    func panelBodyEvaluates() {
        let viewModel = CaptureViewModel { _, _ in
            CaptureOutcome(title: "Probe", isDuplicate: false, routeTargets: [])
        }
        viewModel.updateRingLayout(
            SectorLayout.resolve(
                iconCenter: CGPoint(x: 220, y: 220),
                canvasSize: NovPoolLayout.canvasSize,
                visibleFrameInCanvas: CGRect(origin: .zero, size: NovPoolLayout.canvasSize)
            )
        )

        let host = NSHostingView(
            rootView: PanelRootView(viewModel: viewModel)
        )
        host.frame = NSRect(origin: .zero, size: NovPoolLayout.canvasSize)
        host.layoutSubtreeIfNeeded()
        print("=== Silent state evaluation completed size=\(host.fittingSize)")

        viewModel.dragSessionBegan()
        host.layoutSubtreeIfNeeded()
        print("=== Extended state evaluation completed size=\(host.fittingSize)")

        viewModel.zoneChanged(2)
        host.layoutSubtreeIfNeeded()
        print("=== Highlight evaluation completed")
    }

    @Test("The search panel can be evaluated under three states: empty results / with results / failure")
    func searchPanelBodyEvaluates() async {
        let search = SpySearch()
        search.results = [
            KnowledgeSearchResult(
                id: UUID(),
                title: "Cloud Knowledge Routing",
                summary: "Summary",
                category: "Technology",
                tags: ["swift"],
                contentType: .webLink,
                sourceURL: URL(string: "https://example.com/a"),
                previewBody: "Body",
                isFullTextMatch: true
            ),
            KnowledgeSearchResult(
                id: UUID(),
                title: "Screenshot Preview",
                contentType: .image,
                previewBody: "## FileInformation",
                localFileURL: URL(filePath: "/tmp/novpool-probe.png")
            ),
        ]
        let viewModel = SearchViewModel(
            search: search.make(),
            actions: SpyActions().make(),
            onDismiss: {},
            debounce: .zero
        )

        let host = NSHostingView(rootView: SearchPanelView(viewModel: viewModel))
        host.frame = NSRect(origin: .zero, size: SearchPanelLayout.contentSize)
        host.layoutSubtreeIfNeeded()
        print("=== Search panel idle state evaluation completed")

        viewModel.activate()
        try? await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        print("=== Evaluation of retrieval panel results completed(\(viewModel.results.count) )")

        search.failure = NovPoolError.database("The warehouse is locked")
        viewModel.updateQuery("Trigger failed")
        try? await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        print("=== Failure state evaluation of the search panel completed")
    }

    @Test("Digest ready / over-limit / saved-source views can be evaluated")
    func digestViewsEvaluate() async {
        let search = SpySearch()
        let source = KnowledgeSearchResult(
            id: UUID(),
            title: "Source item",
            summary: "Source summary",
            contentType: .webLink,
            previewBody: "Body"
        )
        search.results = [source]

        let actions = SpyActions()
        actions.digestOutcome = .success(
            DigestDraft(
                title: "Probe digest",
                overview: "Two items about local knowledge.",
                keyPoints: ["Offline", "Searchable"],
                openQuestions: ["Next step?"],
                citations: [DigestCitation(sourceID: source.id, title: source.title)]
            )
        )
        let viewModel = SearchViewModel(
            search: search.make(),
            actions: actions.make(),
            onDismiss: {},
            debounce: .zero,
            digestLimit: 10
        )
        let host = NSHostingView(rootView: SearchPanelView(viewModel: viewModel))
        host.frame = NSRect(origin: .zero, size: SearchPanelLayout.contentSize)

        viewModel.activate()
        try? await Task.sleep(for: .milliseconds(60))
        viewModel.requestDigest()
        try? await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        print("=== Digest ready view evaluation completed")

        viewModel.closeDigest()
        search.results = (0..<11).map {
            KnowledgeSearchResult(id: UUID(), title: "Over \($0)", contentType: .plainText)
        }
        viewModel.updateQuery("over")
        try? await Task.sleep(for: .milliseconds(60))
        viewModel.requestDigest()
        host.layoutSubtreeIfNeeded()
        print("=== Digest limit view evaluation completed")

        viewModel.closeDigest()
        let saved = KnowledgeSearchResult(
            id: UUID(),
            title: "Saved digest",
            summary: "Overview",
            contentType: .digest,
            snippet: "Overview",
            previewBody: "## Overview\nText\n\n## Sources\n1. Source item",
            digestSourceIDs: [source.id]
        )
        search.results = [saved]
        viewModel.updateQuery("saved")
        try? await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        print("=== Saved digest detail view evaluation completed")
    }
}
