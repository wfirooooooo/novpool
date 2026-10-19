import Foundation
import NovPoolStorage

/// Retrieve panel rendering snapshot (pure value).
///
/// The same reason as `PanelSnapshot`: SwiftUI's `ForEach` / gestures / input box callback signatures are all
/// Non-isolated, directly reading `@MainActor` models inside a closure will insert runtime isolation checks.
struct SearchSnapshot: Equatable {
    var query: String
    var focusToken: Int
    var isBusy: Bool
    var phase: SearchViewModel.Phase
    var results: [KnowledgeSearchResult]
    var selectedIndex: Int
    var filter: SearchFilterState
    var availableCategories: [String]
    var statusMessage: String?
    var summarizePhase: SearchViewModel.SummarizePhase
    var isSummarizing: Bool
    var digestPhase: SearchViewModel.DigestPhase
    var digestSelection: Set<UUID>
    var digestLimit: Int
    var digestScopeCount: Int
    var isSavingDigest: Bool
    var isDigesting: Bool
    var canReopenLastDigest: Bool

    var selectedResult: KnowledgeSearchResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    var canShowResults: Bool {
        switch phase {
        case .empty, .failed: false
        default: !results.isEmpty
        }
    }

    @MainActor
    init(viewModel: SearchViewModel) {
        query = viewModel.query
        focusToken = viewModel.focusToken
        isBusy = viewModel.isBusy
        phase = viewModel.phase
        results = viewModel.results
        selectedIndex = viewModel.selectedIndex
        filter = viewModel.filter
        availableCategories = viewModel.availableCategories
        statusMessage = viewModel.statusMessage
        summarizePhase = viewModel.summarizePhase
        isSummarizing = viewModel.isSummarizing
        digestPhase = viewModel.digestPhase
        digestSelection = viewModel.digestSelection
        digestLimit = viewModel.digestLimit
        digestScopeCount = viewModel.digestScope.count
        isSavingDigest = viewModel.isSavingDigest
        isDigesting = viewModel.isDigesting
        canReopenLastDigest = viewModel.canReopenLastDigest
    }
}
