import Foundation
import NovPoolStorage

/// 检索面板渲染快照（纯值）。
///
/// 与 `PanelSnapshot` 同样的理由：SwiftUI 的 `ForEach` / 手势 / 输入框回调签名都是
/// 非隔离的，闭包里直接读 `@MainActor` 模型会插入运行时隔离检查。
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
    }
}
