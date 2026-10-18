import Foundation
import NovPoolStorage
import Observation

/// Actions that the panel can perform, with injections of implementations for unit testing (real implementations use `NSWorkspace` / `NSPasteboard` / Quick Look).
public struct SearchActions: Sendable {
    public var openURL: @MainActor @Sendable (URL) -> Void
    public var revealFile: @MainActor @Sendable (URL) -> Void
    public var copyText: @MainActor @Sendable (String) -> Void
    public var deleteItem: @MainActor @Sendable (UUID) async throws -> Bool
    public var quickLookFile: @MainActor @Sendable (URL) -> Void
    public var updateOrganization: @MainActor @Sendable (UUID, KnowledgeOrganization) async throws -> Void
    /// Return user-facing status text (reason for success or failure).
    public var resummarizeItem: @MainActor @Sendable (UUID) async -> String

    public init(
        openURL: @escaping @MainActor @Sendable (URL) -> Void,
        revealFile: @escaping @MainActor @Sendable (URL) -> Void,
        copyText: @escaping @MainActor @Sendable (String) -> Void,
        deleteItem: @escaping @MainActor @Sendable (UUID) async throws -> Bool = { _ in false },
        quickLookFile: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        updateOrganization: @escaping @MainActor @Sendable (UUID, KnowledgeOrganization) async throws -> Void = { _, _ in },
        resummarizeItem: @escaping @MainActor @Sendable (UUID) async -> String = { _ in "Not wired" }
    ) {
        self.openURL = openURL
        self.revealFile = revealFile
        self.copyText = copyText
        self.deleteItem = deleteItem
        self.quickLookFile = quickLookFile
        self.updateOrganization = updateOrganization
        self.resummarizeItem = resummarizeItem
    }
}

/// Retrieval panel status model.
@MainActor
@Observable
public final class SearchViewModel {
    public enum Phase: Equatable {
        case idle
        case searching
        case results
        case empty
        case failed(String)
    }

    public private(set) var query: String = ""
    public private(set) var results: [KnowledgeSearchResult] = []
    public private(set) var phase: Phase = .idle
    public private(set) var selectedIndex: Int = 0
    /// Each time the panel has an increment, the input box regains focus accordingly.
    public private(set) var focusToken: Int = 0
    public private(set) var isBusy = false
    public private(set) var filter = SearchFilterState()
    public private(set) var availableCategories: [String] = []
    public private(set) var statusMessage: String?

    private let search: @MainActor @Sendable (String) async throws -> [KnowledgeSearchResult]
    private let loadCategories: @MainActor @Sendable () async -> [String]
    private let actions: SearchActions
    private let onDismiss: @MainActor () -> Void
    private let debounce: Duration
    private var searchTask: Task<Void, Never>?
    private var unfilteredResults: [KnowledgeSearchResult] = []

    public init(
        search: @escaping @MainActor @Sendable (String) async throws -> [KnowledgeSearchResult],
        loadCategories: @escaping @MainActor @Sendable () async -> [String] = { [] },
        actions: SearchActions,
        onDismiss: @escaping @MainActor () -> Void,
        debounce: Duration = .milliseconds(120)
    ) {
        self.search = search
        self.loadCategories = loadCategories
        self.actions = actions
        self.onDismiss = onDismiss
        self.debounce = debounce
    }

    public var selectedResult: KnowledgeSearchResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    // MARK: - Lifecycle

    /// The panel displays: clear the query, focus on the input box, and first show Recent items.
    public func activate() {
        searchTask?.cancel()
        query = ""
        selectedIndex = 0
        focusToken += 1
        statusMessage = nil
        phase = .searching
        isBusy = true
        searchTask = Task { [weak self] in
            await self?.refreshCategories()
            await self?.runSearch(for: "")
        }
    }

    public func updateQuery(_ value: String) {
        guard value != query else { return }
        query = value
        scheduleSearch()
    }

    public func dismiss() {
        searchTask?.cancel()
        onDismiss()
    }

    // MARK: - Filtering

    public func setContentKindFilter(_ kind: SearchContentKindFilter) {
        guard filter.contentKind != kind else { return }
        filter.contentKind = kind
        applyFilter()
    }

    public func setCategoryFilter(_ category: String?) {
        guard filter.category != category else { return }
        filter.category = category
        applyFilter()
    }

    public func setTimeFilter(_ time: SearchTimeFilter) {
        guard filter.time != time else { return }
        filter.time = time
        applyFilter()
    }

    public func setFavoritesOnly(_ enabled: Bool) {
        guard filter.favoritesOnly != enabled else { return }
        filter.favoritesOnly = enabled
        applyFilter()
    }

    public func setPinnedOnly(_ enabled: Bool) {
        guard filter.pinnedOnly != enabled else { return }
        filter.pinnedOnly = enabled
        applyFilter()
    }

    public func clearFilters() {
        guard filter.isActive else { return }
        filter = SearchFilterState()
        applyFilter()
    }

    // MARK: - Select

    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), results.count - 1)
        selectedIndex = next
    }

    public func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    // MARK: - Actions

    /// Enter: Open the selected item (Web first, then local File).
    public func confirmSelection() {
        guard let result = selectedResult else { return }
        switch result.defaultAction {
        case .openURL(let url):
            actions.openURL(url)
            dismiss()
        case .revealFile(let url):
            actions.revealFile(url)
            dismiss()
        case .none:
            // Plain Text entries have no jump targets, degrading to Copy, to avoid the Enter key doing nothing.
            copySelection()
        }
    }

    public func copySelection() {
        guard let result = selectedResult else { return }
        actions.copyText(result.clipboardText)
        statusMessage = "Copied"
        clearStatusLater()
    }

    public func revealSelectionInFinder() {
        guard let url = selectedResult?.localFileURL else { return }
        actions.revealFile(url)
    }

    public func quickLookSelection() {
        guard let url = selectedResult?.localFileURL else { return }
        actions.quickLookFile(url)
    }

    public func saveOrganization(_ organization: KnowledgeOrganization) {
        guard let result = selectedResult else { return }
        let id = result.id
        Task { [weak self] in
            guard let self else { return }
            do {
                try await actions.updateOrganization(id, organization)
                if let index = unfilteredResults.firstIndex(where: { $0.id == id }) {
                    unfilteredResults[index].category = organization.category
                    unfilteredResults[index].tags = organization.tags
                    unfilteredResults[index].isPinned = organization.isPinned
                    unfilteredResults[index].isFavorite = organization.isFavorite
                }
                applyFilter()
                await refreshCategories()
                statusMessage = "Organization saved"
                clearStatusLater()
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
                clearStatusLater()
            }
        }
    }

    public func resummarizeSelection() {
        guard let result = selectedResult else { return }
        let id = result.id
        isBusy = true
        statusMessage = "Re-summarizing…"
        Task { [weak self] in
            guard let self else { return }
            let message = await actions.resummarizeItem(id)
            isBusy = false
            statusMessage = message
            // On success, refresh the current query so the new summary appears.
            if message.hasPrefix("Re-summarized") {
                await runSearch(for: query)
            }
            clearStatusLater()
        }
    }

    public func deleteSelection() {
        guard let result = selectedResult else { return }
        let id = result.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let removed = try await actions.deleteItem(id)
                guard removed else {
                    statusMessage = "Delete failed"
                    clearStatusLater()
                    return
                }
                unfilteredResults.removeAll { $0.id == id }
                applyFilter()
                statusMessage = "Deleted \"\(result.title)\""
                clearStatusLater()
            } catch {
                statusMessage = "Delete failed: \(error.localizedDescription)"
                clearStatusLater()
            }
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        isBusy = true
        if results.isEmpty { phase = .searching }
        searchTask = Task { [weak self, query, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.runSearch(for: query)
        }
    }

    private func runSearch(for query: String) async {
        defer { isBusy = false }
        do {
            let hits = try await search(query)
            guard !Task.isCancelled else { return }
            unfilteredResults = hits
            selectedIndex = 0
            applyFilter()
        } catch {
            guard !Task.isCancelled else { return }
            unfilteredResults = []
            results = []
            selectedIndex = 0
            phase = .failed(error.localizedDescription)
        }
    }

    private func applyFilter() {
        let filtered = filter.applying(to: unfilteredResults)
        results = filtered
        if selectedIndex >= filtered.count {
            selectedIndex = max(filtered.count - 1, 0)
        }
        phase = filtered.isEmpty ? .empty : .results
    }

    private func refreshCategories() async {
        availableCategories = await loadCategories()
    }

    private func clearStatusLater() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.statusMessage = nil
        }
    }
}
