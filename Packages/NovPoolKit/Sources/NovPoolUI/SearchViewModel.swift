import Foundation
import NovPoolStorage
import Observation

/// 面板可以执行的动作，注入实现以便单元测试（真实实现走 `NSWorkspace` / `NSPasteboard`）。
public struct SearchActions: Sendable {
    public var openURL: @MainActor @Sendable (URL) -> Void
    public var revealFile: @MainActor @Sendable (URL) -> Void
    public var copyText: @MainActor @Sendable (String) -> Void

    public init(
        openURL: @escaping @MainActor @Sendable (URL) -> Void,
        revealFile: @escaping @MainActor @Sendable (URL) -> Void,
        copyText: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.openURL = openURL
        self.revealFile = revealFile
        self.copyText = copyText
    }
}

/// 检索面板状态模型。
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
    /// 每次面板出现自增，输入框据此重新取得焦点。
    public private(set) var focusToken: Int = 0
    public private(set) var isBusy = false

    private let search: @MainActor @Sendable (String) async throws -> [KnowledgeSearchResult]
    private let actions: SearchActions
    private let onDismiss: @MainActor () -> Void
    private let debounce: Duration
    private var searchTask: Task<Void, Never>?

    public init(
        search: @escaping @MainActor @Sendable (String) async throws -> [KnowledgeSearchResult],
        actions: SearchActions,
        onDismiss: @escaping @MainActor () -> Void,
        debounce: Duration = .milliseconds(120)
    ) {
        self.search = search
        self.actions = actions
        self.onDismiss = onDismiss
        self.debounce = debounce
    }

    public var selectedResult: KnowledgeSearchResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    // MARK: - 生命周期

    /// 面板出现：清空查询、聚焦输入框、先展示最近条目。
    public func activate() {
        searchTask?.cancel()
        query = ""
        selectedIndex = 0
        focusToken += 1
        phase = .searching
        isBusy = true
        searchTask = Task { [weak self] in
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

    // MARK: - 选择

    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), results.count - 1)
        selectedIndex = next
    }

    public func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    // MARK: - 动作

    /// 回车：打开选中条目（网页优先，其次本地文件）。
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
            // 纯文本条目没有可跳转目标，退化为复制，避免回车毫无反应。
            copySelection()
        }
    }

    public func copySelection() {
        guard let result = selectedResult else { return }
        actions.copyText(result.clipboardText)
    }

    // MARK: - 检索

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
            results = hits
            selectedIndex = 0
            phase = hits.isEmpty ? .empty : .results
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            selectedIndex = 0
            phase = .failed(error.localizedDescription)
        }
    }
}
