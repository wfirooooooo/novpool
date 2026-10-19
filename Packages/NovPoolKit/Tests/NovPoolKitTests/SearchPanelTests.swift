import AppKit
import Carbon.HIToolbox
import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolUI

/// Record the substitute for action calls (global actor isolation, no need for locking in tests).
@MainActor
final class SpyActions {
    private(set) var openedURLs: [URL] = []
    private(set) var revealedFiles: [URL] = []
    private(set) var copiedText: [String] = []
    private(set) var deletedIDs: [UUID] = []
    private(set) var quickLookedFiles: [URL] = []
    private(set) var organizations: [(UUID, KnowledgeOrganization)] = []
    private(set) var resummarizedIDs: [UUID] = []
    var resummarizeMessage = "Re-summarized (AI tags)"
    var resummarizeOutcome: ResummarizeFeedback.Outcome = .updated
    private(set) var dismissCount = 0

    func make() -> SearchActions {
        SearchActions(
            openURL: { [self] in openedURLs.append($0) },
            revealFile: { [self] in revealedFiles.append($0) },
            copyText: { [self] in copiedText.append($0) },
            deleteItem: { [self] id in
                deletedIDs.append(id)
                return true
            },
            quickLookFile: { [self] in quickLookedFiles.append($0) },
            updateOrganization: { [self] id, organization in
                organizations.append((id, organization))
            },
            resummarizeItem: { [self] id in
                resummarizedIDs.append(id)
                return ResummarizeFeedback(outcome: resummarizeOutcome, message: resummarizeMessage)
            }
        )
    }
}

/// A substitute that records query strings and returns preset results.
@MainActor
final class SpySearch {
    private(set) var queries: [String] = []
    var results: [KnowledgeSearchResult] = []
    var failure: Error?

    func make() -> @MainActor @Sendable (String) async throws -> [KnowledgeSearchResult] {
        { [self] query in
            queries.append(query)
            if let failure { throw failure }
            return results
        }
    }
}

@Suite("Search panel behavior")
@MainActor
struct SearchPanelTests {
    private func makeViewModel(
        search: SpySearch = SpySearch(),
        actions: SpyActions = SpyActions(),
        onDismiss: @escaping @MainActor () -> Void = {}
    ) -> (SearchViewModel, SpySearch, SpyActions) {
        let viewModel = SearchViewModel(
            search: search.make(),
            actions: actions.make(),
            onDismiss: onDismiss,
            debounce: .zero
        )
        return (viewModel, search, actions)
    }

    private func sample(
        title: String = "entry",
        url: String? = nil,
        fileURL: URL? = nil,
        summary: String? = nil
    ) -> KnowledgeSearchResult {
        KnowledgeSearchResult(
            id: UUID(),
            title: title,
            summary: summary,
            contentType: .webLink,
            sourceURL: url.flatMap(URL.init(string:)),
            previewBody: "Body",
            localFileURL: fileURL
        )
    }

    /// Waiting for the Douyin task to finish running.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: - Lifecycle

    @Test("Invoke panel: clear query, increment focus token, load Recent entries first")
    func activateLoadsRecent() async {
        let search = SpySearch()
        search.results = [sample(title: "Recententry")]
        let (viewModel, spy, _) = makeViewModel(search: search)

        viewModel.updateQuery("Residual old queries")
        await settle()
        viewModel.activate()
        await settle()

        #expect(viewModel.query.isEmpty)
        #expect(viewModel.focusToken == 1)
        #expect(spy.queries.last == "")
        #expect(viewModel.results.count == 1)
        #expect(viewModel.phase == .results)
        #expect(viewModel.selectedIndex == 0)
    }

    @Test("Enter to trigger the search, after the results are ready, select the first item")
    func queryDrivesSearch() async {
        let search = SpySearch()
        search.results = [sample(title: "A"), sample(title: "B"), sample(title: "C")]
        let (viewModel, spy, _) = makeViewModel(search: search)

        viewModel.activate()
        await settle()
        viewModel.moveSelection(by: 2)
        #expect(viewModel.selectedIndex == 2)

        viewModel.updateQuery("Cloud Routing")
        await settle()

        #expect(spy.queries.last == "Cloud Routing")
        #expect(viewModel.selectedIndex == 0)
        #expect(viewModel.phase == .results)
        #expect(viewModel.isBusy == false)
    }

    @Test("Both 'no results' and 'search failure' have clear statuses, and the panel will not get stuck on blank.")
    func emptyAndFailureStates() async {
        let search = SpySearch()
        search.results = []
        let (viewModel, _, _) = makeViewModel(search: search)
        viewModel.activate()
        await settle()
        #expect(viewModel.phase == .empty)

        let failing = SpySearch()
        failing.failure = NovPoolError.database("The warehouse is locked")
        let (failingViewModel, _, _) = makeViewModel(search: failing)
        failingViewModel.activate()
        await settle()
        if case .failed(let message) = failingViewModel.phase {
            #expect(message.contains("The warehouse is locked"))
        } else {
            Issue.record("When the search fails, it should enter the failed state; in reality, it is\(failingViewModel.phase)")
        }
        #expect(failingViewModel.results.isEmpty)
    }

    // MARK: - Select

    @Test("Move up and down and clamp at both ends, without going out of bounds")
    func selectionClamping() async {
        let search = SpySearch()
        search.results = [sample(title: "A"), sample(title: "B")]
        let (viewModel, _, _) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.moveSelection(by: -1)
        #expect(viewModel.selectedIndex == 0)
        viewModel.moveSelection(by: 5)
        #expect(viewModel.selectedIndex == 1)
        viewModel.select(99)
        #expect(viewModel.selectedIndex == 1)
        #expect(viewModel.selectedResult?.title == "B")
    }

    @Test("Moving Select does not crash when the result is empty")
    func selectionWithNoResults() async {
        let search = SpySearch()
        search.results = []
        let (viewModel, _, _) = makeViewModel(search: search)
        viewModel.activate()
        await settle()
        viewModel.moveSelection(by: 1)
        #expect(viewModel.selectedResult == nil)
    }

    // MARK: - Actions

    @Test("Press Enter to open the Web entry and collapse the panel")
    func confirmOpensWebResult() async {
        let search = SpySearch()
        search.results = [sample(title: "Article", url: "https://example.com/a")]
        var dismissed = 0
        let (viewModel, _, actions) = makeViewModel(search: search, onDismiss: { dismissed += 1 })
        viewModel.activate()
        await settle()

        viewModel.confirmSelection()
        #expect(actions.openedURLs == [URL(string: "https://example.com/a")!])
        #expect(actions.revealedFiles.isEmpty)
        #expect(dismissed == 1)
    }

    @Test("Press Enter to Open a purely local File entry")
    func confirmRevealsLocalFile() async {
        let file = URL(filePath: "/tmp/novpool-report.pdf")
        let search = SpySearch()
        search.results = [sample(title: "Local Report", fileURL: file)]
        var dismissed = 0
        let (viewModel, _, actions) = makeViewModel(search: search, onDismiss: { dismissed += 1 })
        viewModel.activate()
        await settle()

        viewModel.confirmSelection()
        #expect(actions.revealedFiles == [file])
        #expect(actions.openedURLs.isEmpty)
        #expect(dismissed == 1)
    }

    @Test("Entries with neither Link nor File revert to Copy, preventing Enter from having no response.")
    func confirmFallsBackToCopy() async {
        let search = SpySearch()
        search.results = [sample(title: "Plain TextNotes", summary: "Summary")]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.confirmSelection()
        #expect(actions.copiedText.count == 1)
        #expect(actions.copiedText[0].contains("Plain TextNotes"))
    }

    @Test("Copy button write clipboard Text")
    func copySelection() async {
        let search = SpySearch()
        search.results = [sample(title: "A"), sample(title: "B")]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.moveSelection(by: 1)
        viewModel.copySelection()
        #expect(actions.copiedText.count == 1)
        #expect(actions.copiedText[0].contains("# B"))
    }

    @Test("After deleting the selected item, remove it from the results list")
    func deleteSelectionRemovesResult() async {
        let search = SpySearch()
        let first = sample(title: "A")
        let second = sample(title: "B")
        search.results = [first, second]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.deleteSelection()
        await settle()

        #expect(actions.deletedIDs == [first.id])
        #expect(viewModel.results.map(\.title) == ["B"])
        #expect(viewModel.selectedResult?.title == "B")
    }

    @Test("Narrow results by type and time")
    func filtersNarrowResults() async {
        let search = SpySearch()
        let web = KnowledgeSearchResult(
            id: UUID(),
            title: "Web",
            contentType: .webLink,
            sourceURL: URL(string: "https://example.com"),
            createdAt: Date()
        )
        let oldFile = KnowledgeSearchResult(
            id: UUID(),
            title: "Old File",
            contentType: .genericFile,
            createdAt: Date().addingTimeInterval(-40 * 24 * 3600)
        )
        search.results = [web, oldFile]
        let (viewModel, _, _) = makeViewModel(search: search)
        viewModel.activate()
        await settle()
        #expect(viewModel.results.count == 2)

        viewModel.setContentKindFilter(.web)
        #expect(viewModel.results.map(\.title) == ["Web"])

        viewModel.setContentKindFilter(.file)
        viewModel.setTimeFilter(.month)
        #expect(viewModel.results.isEmpty)

        viewModel.clearFilters()
        #expect(viewModel.results.count == 2)
    }

    @Test("Finder button reveals local File")
    func revealInFinder() async {
        let file = URL(filePath: "/tmp/novpool-local.txt")
        let search = SpySearch()
        search.results = [sample(title: "Local", fileURL: file)]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.revealSelectionInFinder()
        #expect(actions.revealedFiles == [file])
    }

    @Test("The Preview button triggers Quick Look")
    func quickLookSelection() async {
        let file = URL(filePath: "/tmp/novpool-preview.png")
        let search = SpySearch()
        search.results = [sample(title: "Image", fileURL: file)]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        viewModel.quickLookSelection()
        #expect(actions.quickLookedFiles == [file])
    }

    @Test("Re-summarize calls the injection action and displays the status")
    func resummarizeSelection() async {
        let search = SpySearch()
        let item = sample(title: "To be summarized")
        search.results = [item]
        let actions = SpyActions()
        let (viewModel, _, _) = makeViewModel(search: search, actions: actions)
        viewModel.activate()
        await settle()

        viewModel.resummarizeSelection()
        await settle()
        await settle()

        #expect(actions.resummarizedIDs == [item.id])
        #expect(viewModel.statusMessage?.contains("Re-summarize") == true)
        if case .succeeded(let id, _) = viewModel.summarizePhase {
            #expect(id == item.id)
        } else {
            Issue.record("Expected a finished summarize state")
        }
    }

    @Test("Replacing an existing summary waits for confirmation")
    func forceResummarizeRequiresConfirmation() async {
        let search = SpySearch()
        let item = sample(title: "Already summarized", summary: "Old summary")
        search.results = [item]
        let actions = SpyActions()
        let (viewModel, _, _) = makeViewModel(search: search, actions: actions)
        viewModel.activate()
        await settle()

        viewModel.resummarizeSelection()
        await settle()
        #expect(actions.resummarizedIDs.isEmpty)
        if case .needsForceConfirm(let id) = viewModel.summarizePhase {
            #expect(id == item.id)
        } else {
            Issue.record("Expected a confirmation state")
        }

        viewModel.cancelForceResummarize()
        #expect(actions.resummarizedIDs.isEmpty)
        if case .idle = viewModel.summarizePhase {} else {
            Issue.record("Cancel should return to idle")
        }

        viewModel.resummarizeSelection()
        viewModel.confirmForceResummarize()
        await settle()
        await settle()
        #expect(actions.resummarizedIDs == [item.id])
    }

    @Test("A failed summarize stays visible and Retry runs it again")
    func failedSummarizeCanRetry() async {
        let search = SpySearch()
        let item = sample(title: "Needs a summary")
        search.results = [item]
        let actions = SpyActions()
        actions.resummarizeOutcome = .failed
        actions.resummarizeMessage = "Summarize failed: model unavailable"
        let (viewModel, _, _) = makeViewModel(search: search, actions: actions)
        viewModel.activate()
        await settle()

        viewModel.resummarizeSelection()
        await settle()
        await settle()
        #expect(actions.resummarizedIDs == [item.id])
        if case .failed(let id, let message) = viewModel.summarizePhase {
            #expect(id == item.id)
            #expect(message.contains("model unavailable"))
        } else {
            Issue.record("Expected a failed summarize state")
        }

        viewModel.resummarizeSelection()
        await settle()
        await settle()
        #expect(actions.resummarizedIDs == [item.id, item.id])
    }

    @Test("Update the results after SaveOrganize and support Favorite filtering")
    func saveOrganizationAndFavoriteFilter() async {
        let search = SpySearch()
        let item = KnowledgeSearchResult(
            id: UUID(),
            title: "To be organized",
            category: "old",
            tags: ["a"],
            contentType: .plainText
        )
        search.results = [item]
        let (viewModel, _, actions) = makeViewModel(search: search)
        viewModel.activate()
        await settle()

        let organization = KnowledgeOrganization(
            category: "Technology",
            tags: ["swift"],
            isPinned: true,
            isFavorite: true
        )
        viewModel.saveOrganization(organization)
        await settle()

        #expect(actions.organizations.count == 1)
        #expect(actions.organizations[0].0 == item.id)
        #expect(viewModel.selectedResult?.category == "Technology")
        #expect(viewModel.selectedResult?.tags == ["swift"])
        #expect(viewModel.selectedResult?.isPinned == true)
        #expect(viewModel.selectedResult?.isFavorite == true)

        viewModel.setFavoritesOnly(true)
        #expect(viewModel.results.count == 1)

        viewModel.saveOrganization(
            KnowledgeOrganization(category: "Technology", tags: ["swift"], isPinned: true, isFavorite: false)
        )
        await settle()
        #expect(viewModel.results.isEmpty)
    }
}

@Suite("Search Panel Layout and Shortcut Specifications")
struct SearchPanelLayoutTests {
    @Test("The panel is horizontally centered, slightly above the screen center vertically, and fully within the visible area.")
    func placement() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let origin = SearchPanelPlacement.origin(in: visible)
        let frame = NSRect(origin: origin, size: SearchPanelLayout.contentSize)

        #expect(frame.midX == visible.midX)
        #expect(visible.contains(frame))
        #expect(frame.midY > visible.midY)
    }

    @Test("Window size can be persisted, and if it is too small, it will be clamped to the minimum size")
    func contentSizePersistence() {
        let suite = "novpool.tests.searchPanel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SearchPanelLayout.resolvedContentSize(defaults: defaults) == SearchPanelLayout.contentSize)

        SearchPanelLayout.persistContentSize(CGSize(width: 1000, height: 700), defaults: defaults)
        #expect(SearchPanelLayout.resolvedContentSize(defaults: defaults) == CGSize(width: 1000, height: 700))

        SearchPanelLayout.persistContentSize(CGSize(width: 100, height: 50), defaults: defaults)
        let clamped = SearchPanelLayout.resolvedContentSize(defaults: defaults)
        #expect(clamped.width == SearchPanelLayout.minimumContentSize.width)
        #expect(clamped.height == SearchPanelLayout.minimumContentSize.height)
    }

    @Test("Multiple monitors: pop up on the screen where the mouse is located; if not found, return to the primary screen")
    func screenSelection() {
        let primary = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let secondary = NSRect(x: 1512, y: 0, width: 1280, height: 800)
        let frames = [primary, secondary]

        #expect(SearchPanelPlacement.screenIndex(containing: NSPoint(x: 100, y: 100), frames: frames) == 0)
        #expect(SearchPanelPlacement.screenIndex(containing: NSPoint(x: 1800, y: 300), frames: frames) == 1)
        #expect(SearchPanelPlacement.screenIndex(containing: NSPoint(x: -500, y: -500), frames: frames) == 0)
        #expect(SearchPanelPlacement.screenIndex(containing: .zero, frames: []) == nil)
    }

    @Test("Hotkey Analysis: Default Combination, Alias, Order Irrelevant, Invalid Input")
    func hotKeyParsing() {
        let spec = HotKeySpec(named: "cmd+shift+space")
        #expect(spec?.keyCode == HotKeySpec.default.keyCode)
        #expect(spec?.carbonModifiers == HotKeySpec.default.carbonModifiers)
        #expect(spec?.displayName == "⇧⌘Space")

        #expect(HotKeySpec(named: "shift+cmd+k") == HotKeySpec(named: "command+shift+k"))
        #expect(HotKeySpec(named: "⌥+space")?.displayName == "⌥Space")
        #expect(HotKeySpec(named: "ctrl+alt+a")?.carbonModifiers == UInt32(controlKey | optionKey))

        #expect(HotKeySpec(named: "space") == nil)          // Missing modifier key
        #expect(HotKeySpec(named: "cmd+shift") == nil)      // Missing primary key
        #expect(HotKeySpec(named: "cmd+unknown") == nil)    // Unrecognized key name
        #expect(HotKeySpec(named: "") == nil)
    }
}
