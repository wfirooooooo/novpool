import Foundation
import NovPoolStorage
import NovPoolSystemBridge
import Observation

/// Actions that the panel can perform, with injections of implementations for unit testing (real implementations use `NSWorkspace` / `NSPasteboard` / Quick Look).
public struct SearchActions: Sendable {
    public var openURL: @MainActor @Sendable (URL) -> Void
    public var revealFile: @MainActor @Sendable (URL) -> Void
    public var copyText: @MainActor @Sendable (String) -> Void
    public var deleteItem: @MainActor @Sendable (UUID) async throws -> Bool
    public var quickLookFile: @MainActor @Sendable (URL) -> Void
    public var updateOrganization: @MainActor @Sendable (UUID, KnowledgeOrganization) async throws -> Void
    /// Return whether the write succeeded, plus user-facing status text.
    public var resummarizeItem: @MainActor @Sendable (UUID) async -> ResummarizeFeedback
    /// Generate one cross-item digest from the supplied summaries.
    public var digestItems: @MainActor @Sendable ([DigestSource]) async -> DigestOutcome
    /// Persist a successful digest and return the new knowledge item ID.
    public var saveDigest: @MainActor @Sendable (DigestDraft) async throws -> UUID
    /// Load a source item that is not in the current result list (saved digest citations).
    public var loadItem: @MainActor @Sendable (UUID) async -> KnowledgeSearchResult?

    public init(
        openURL: @escaping @MainActor @Sendable (URL) -> Void,
        revealFile: @escaping @MainActor @Sendable (URL) -> Void,
        copyText: @escaping @MainActor @Sendable (String) -> Void,
        deleteItem: @escaping @MainActor @Sendable (UUID) async throws -> Bool = { _ in false },
        quickLookFile: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        updateOrganization: @escaping @MainActor @Sendable (UUID, KnowledgeOrganization) async throws -> Void = { _, _ in },
        resummarizeItem: @escaping @MainActor @Sendable (UUID) async -> ResummarizeFeedback = { _ in .notWired },
        digestItems: @escaping @MainActor @Sendable ([DigestSource]) async -> DigestOutcome = { _ in
            .failure("Digest is not wired")
        },
        saveDigest: @escaping @MainActor @Sendable (DigestDraft) async throws -> UUID = { _ in
            throw SearchActionError.notWired
        },
        loadItem: @escaping @MainActor @Sendable (UUID) async -> KnowledgeSearchResult? = { _ in nil }
    ) {
        self.openURL = openURL
        self.revealFile = revealFile
        self.copyText = copyText
        self.deleteItem = deleteItem
        self.quickLookFile = quickLookFile
        self.updateOrganization = updateOrganization
        self.resummarizeItem = resummarizeItem
        self.digestItems = digestItems
        self.saveDigest = saveDigest
        self.loadItem = loadItem
    }
}

public enum SearchActionError: LocalizedError {
    case notWired

    public var errorDescription: String? { "Saving digests is not wired" }
}

/// Outcome of one single-item summarize call. The panel does not sniff message prefixes.
public struct ResummarizeFeedback: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case updated
        case failed
    }

    public var outcome: Outcome
    public var message: String

    public init(outcome: Outcome, message: String) {
        self.outcome = outcome
        self.message = message
    }

    public static let notWired = ResummarizeFeedback(outcome: .failed, message: "Not wired")
}

/// Retrieval panel status model.
@MainActor
@Observable
public final class SearchViewModel {
    /// Single-item summarize. Force-replacing an existing summary stays in `needsForceConfirm` until the user agrees.
    public enum SummarizePhase: Equatable, Sendable {
        case idle
        case needsForceConfirm(UUID)
        case running(UUID)
        case succeeded(UUID, String)
        case failed(UUID, String)
    }

    public enum Phase: Equatable {
        case idle
        case searching
        case results
        case empty
        case failed(String)
    }

    /// Digest lifecycle. The generated draft stays view-only until the user saves it.
    public enum DigestPhase: Equatable, Sendable {
        case idle
        case running
        case ready(DigestDraft)
        case limitExceeded(count: Int, limit: Int)
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
    public private(set) var summarizePhase: SummarizePhase = .idle
    public private(set) var digestPhase: DigestPhase = .idle
    /// Explicit multi-select for digest input. Empty means "use the current filtered results".
    public private(set) var digestSelection: Set<UUID> = []
    public private(set) var lastDigest: DigestDraft?
    public private(set) var isSavingDigest = false
    public private(set) var digestLimit: Int

    private let search: @MainActor @Sendable (String) async throws -> [KnowledgeSearchResult]
    private let loadCategories: @MainActor @Sendable () async -> [String]
    private let actions: SearchActions
    private let onDismiss: @MainActor () -> Void
    private let debounce: Duration
    private var searchTask: Task<Void, Never>?
    private var digestTask: Task<Void, Never>?
    private var unfilteredResults: [KnowledgeSearchResult] = []

    public init(
        search: @escaping @MainActor @Sendable (String) async throws -> [KnowledgeSearchResult],
        loadCategories: @escaping @MainActor @Sendable () async -> [String] = { [] },
        actions: SearchActions,
        onDismiss: @escaping @MainActor () -> Void,
        debounce: Duration = .milliseconds(120),
        digestLimit: Int = DigestLimits.defaultMaxItems
    ) {
        self.search = search
        self.loadCategories = loadCategories
        self.actions = actions
        self.onDismiss = onDismiss
        self.debounce = debounce
        self.digestLimit = DigestLimits.clamp(digestLimit)
    }

    public var selectedResult: KnowledgeSearchResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    public func updateDigestLimit(_ value: Int) {
        digestLimit = DigestLimits.clamp(value)
    }

    /// Explicitly selected items still visible in the current results.
    public var selectedDigestResults: [KnowledgeSearchResult] {
        guard !digestSelection.isEmpty else { return [] }
        return results.filter { digestSelection.contains($0.id) }
    }

    /// Selection wins; otherwise the current filter set is the digest scope.
    public var digestScope: [KnowledgeSearchResult] {
        let selected = selectedDigestResults
        return selected.isEmpty ? results : selected
    }

    public var isDigesting: Bool {
        if case .running = digestPhase { return true }
        return false
    }

    public var canReopenLastDigest: Bool {
        lastDigest != nil && digestPhase == .idle
    }

    // MARK: - Lifecycle

    /// The panel displays: clear the query, focus on the input box, and first show Recent items.
    public func activate() {
        searchTask?.cancel()
        digestTask?.cancel()
        digestTask = nil
        query = ""
        selectedIndex = 0
        focusToken += 1
        statusMessage = nil
        summarizePhase = .idle
        digestPhase = .idle
        digestSelection = []
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
        digestSelection = []
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

    // MARK: - Digest

    public func toggleDigestSelection(_ id: UUID) {
        guard results.contains(where: { $0.id == id }) else { return }
        if digestSelection.contains(id) {
            digestSelection.remove(id)
        } else {
            digestSelection.insert(id)
        }
    }

    public func clearDigestSelection() {
        digestSelection = []
    }

    /// Build a digest from explicit selections, or from the current filtered result set.
    public func requestDigest() {
        guard !isDigesting else { return }
        let scope = digestScope
        guard !scope.isEmpty else {
            statusMessage = "Nothing to digest"
            clearStatusLater()
            return
        }
        let limit = digestLimit
        guard scope.count <= limit else {
            digestPhase = .limitExceeded(count: scope.count, limit: limit)
            statusMessage = "Digest limit: \(limit) items (this scope has \(scope.count))"
            return
        }

        let sources = scope.map {
            DigestSource(id: $0.id, title: $0.title, summary: $0.summary, bodyExcerpt: $0.previewBody)
        }
        digestPhase = .running
        statusMessage = "Writing digest…"
        digestTask?.cancel()
        digestTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await actions.digestItems(sources)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let draft):
                digestPhase = .ready(draft)
                lastDigest = draft
                statusMessage = "Digest ready (\(draft.citations.count) sources)"
            case .failure(let reason):
                digestPhase = .failed(reason)
                statusMessage = reason
            }
        }
    }

    public func closeDigest() {
        digestTask?.cancel()
        digestTask = nil
        if case .ready(let draft) = digestPhase {
            lastDigest = draft
        }
        digestPhase = .idle
    }

    public func reopenLastDigest() {
        guard let lastDigest else { return }
        digestPhase = .ready(lastDigest)
    }

    public func saveDigest() {
        guard case .ready(let draft) = digestPhase,
              draft.savedItemID == nil,
              !isSavingDigest else { return }
        isSavingDigest = true
        let original = draft
        Task { [weak self] in
            guard let self else { return }
            defer { isSavingDigest = false }
            do {
                let id = try await actions.saveDigest(draft)
                var savedDraft = original
                savedDraft.savedItemID = id
                lastDigest = savedDraft
                if case .ready(let current) = digestPhase, current == original {
                    digestPhase = .ready(savedDraft)
                }
                statusMessage = "Saved to knowledge base"
                // Refresh so the new digest is searchable immediately.
                await runSearch(for: query)
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    /// Citation click: close the digest and show that source item.
    public func openCitation(_ sourceID: UUID) {
        if let index = results.firstIndex(where: { $0.id == sourceID }) {
            finishCitationNavigation(index: index)
            return
        }
        statusMessage = "Loading source…"
        Task { [weak self] in
            guard let self else { return }
            guard let item = await actions.loadItem(sourceID) else {
                statusMessage = "Source item is no longer in the library."
                clearStatusLater()
                return
            }
            // Keep the source visible even when the active filters would hide it.
            if !unfilteredResults.contains(where: { $0.id == sourceID }) {
                unfilteredResults.insert(item, at: 0)
            }
            results.insert(item, at: 0)
            finishCitationNavigation(index: 0)
        }
    }

    private func finishCitationNavigation(index: Int) {
        if case .ready(let draft) = digestPhase {
            lastDigest = draft
        }
        digestPhase = .idle
        selectedIndex = index
        statusMessage = nil
    }

    // MARK: - Select

    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        if digestPhase != .idle { closeDigest() }
        let previousID = selectedResult?.id
        let next = min(max(selectedIndex + delta, 0), results.count - 1)
        selectedIndex = next
        resetSummarizeChromeIfSelectionChanged(from: previousID)
    }

    public func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        if digestPhase != .idle { closeDigest() }
        let previousID = selectedResult?.id
        selectedIndex = index
        resetSummarizeChromeIfSelectionChanged(from: previousID)
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

    public var isSummarizing: Bool {
        if case .running = summarizePhase { return true }
        return false
    }

    /// Fill a missing summary immediately. Replacing an existing summary waits for `confirmForceResummarize()`.
    public func resummarizeSelection() {
        guard let result = selectedResult else { return }
        guard !isSummarizing else { return }
        if case .failed(let id, _) = summarizePhase, id == result.id {
            startResummarize(id: id)
            return
        }
        if result.hasExistingSummary {
            summarizePhase = .needsForceConfirm(result.id)
            statusMessage = "This item already has a summary. Confirm to replace it."
            return
        }
        startResummarize(id: result.id)
    }

    public func confirmForceResummarize() {
        guard case .needsForceConfirm(let id) = summarizePhase else { return }
        guard selectedResult?.id == id else {
            summarizePhase = .idle
            statusMessage = nil
            return
        }
        startResummarize(id: id)
    }

    public func cancelForceResummarize() {
        guard case .needsForceConfirm = summarizePhase else { return }
        summarizePhase = .idle
        statusMessage = nil
    }

    private func startResummarize(id: UUID) {
        summarizePhase = .running(id)
        statusMessage = "Summarizing…"
        Task { [weak self] in
            guard let self else { return }
            let feedback = await actions.resummarizeItem(id)
            statusMessage = feedback.message
            switch feedback.outcome {
            case .updated:
                summarizePhase = .succeeded(id, feedback.message)
            case .failed:
                summarizePhase = .failed(id, feedback.message)
            }
            // FTS updates from the row trigger; reload so summary, topic, tags, and failure text match the write.
            await runSearch(for: query)
            if let index = results.firstIndex(where: { $0.id == id }) {
                selectedIndex = index
            }
            if case .updated = feedback.outcome {
                await refreshCategories()
            }
        }
    }

    private func resetSummarizeChromeIfSelectionChanged(from previousID: UUID?) {
        guard previousID != selectedResult?.id else { return }
        if case .running = summarizePhase { return }
        summarizePhase = .idle
        statusMessage = nil
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
        digestSelection.formIntersection(Set(filtered.map(\.id)))
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
