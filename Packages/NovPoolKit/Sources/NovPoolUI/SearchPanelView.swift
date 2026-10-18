import AppKit
import NovPoolCore
import NovPoolStorage
import SwiftUI

/// 检索面板内容视图：左侧列表 + 右侧详情（`HSplitView` 可拖动分栏）。
@MainActor
public struct SearchPanelView: View {
    private let viewModel: SearchViewModel

    public init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        // 快照在 body 作用域内取值（main actor），后面的闭包只消费纯值。
        render(SearchSnapshot(viewModel: viewModel))
    }

    private func render(_ snapshot: SearchSnapshot) -> some View {
        HSplitView {
            listColumn(snapshot)
                .frame(minWidth: SearchPanelLayout.minimumListColumnWidth)
                .layoutPriority(1)

            previewColumn(snapshot)
                .frame(minWidth: SearchPanelLayout.minimumPreviewColumnWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 与设置 Form 一致：系统窗口底色，而不是半透明毛玻璃。
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - 左列

    private func listColumn(_ snapshot: SearchSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                SearchFieldView(
                    text: snapshot.query,
                    placeholder: "搜索本地知识库（标题、正文、OCR、标签、来源）",
                    focusToken: snapshot.focusToken,
                    onTextChange: { [viewModel] text in viewModel.updateQuery(text) },
                    onMoveUp: { [viewModel] in viewModel.moveSelection(by: -1) },
                    onMoveDown: { [viewModel] in viewModel.moveSelection(by: 1) },
                    onSubmit: { [viewModel] in viewModel.confirmSelection() },
                    onCancel: { [viewModel] in viewModel.dismiss() }
                )
                .frame(height: 26)
                if snapshot.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            filterBar(snapshot)

            Divider()

            resultList(snapshot)

            Divider()
            footer(snapshot)
        }
    }

    private func filterBar(_ snapshot: SearchSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 资源形态筛选（网页/图/视频…）≠ 主题分类
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("形态")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ForEach(SearchContentKindFilter.allCases) { kind in
                        filterChip(
                            kind.title,
                            selected: snapshot.filter.contentKind == kind
                        ) { [viewModel] in
                            viewModel.setContentKindFilter(kind)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }

            HStack(spacing: 8) {
                Picker(
                    "时间",
                    selection: Binding(
                        get: { snapshot.filter.time },
                        set: { [viewModel] value in viewModel.setTimeFilter(value) }
                    )
                ) {
                    ForEach(SearchTimeFilter.allCases) { time in
                        Text(time.title).tag(time)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)

                Picker(
                    "主题",
                    selection: Binding(
                        get: { snapshot.filter.category ?? "" },
                        set: { [viewModel] value in
                            viewModel.setCategoryFilter(value.isEmpty ? nil : value)
                        }
                    )
                ) {
                    Text("全部主题").tag("")
                    ForEach(snapshot.availableCategories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 140)
                .help("按内容主题筛选，不是按文件类型")

                filterChip(
                    "收藏",
                    selected: snapshot.filter.favoritesOnly
                ) { [viewModel] in
                    viewModel.setFavoritesOnly(!snapshot.filter.favoritesOnly)
                }

                filterChip(
                    "置顶",
                    selected: snapshot.filter.pinnedOnly
                ) { [viewModel] in
                    viewModel.setPinnedOnly(!snapshot.filter.pinnedOnly)
                }

                if snapshot.filter.isActive {
                    Button("清除筛选") { [viewModel] in
                        viewModel.clearFilters()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .controlSize(.small)
        }
        .padding(.bottom, 8)
    }

    private func filterChip(
        _ title: String,
        selected: Bool,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: { Task { @MainActor in action() } }) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                )
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func resultList(_ snapshot: SearchSnapshot) -> some View {
        switch snapshot.phase {
        case .empty:
            placeholder(
                icon: "tray",
                text: snapshot.filter.isActive ? "没有符合筛选条件的条目" : "没有匹配的条目"
            )
        case .failed(let message):
            placeholder(icon: "exclamationmark.triangle", text: message)
        default:
            if snapshot.results.isEmpty {
                placeholder(icon: "clock", text: snapshot.isBusy ? "正在检索…" : "还没有收录任何内容")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(snapshot.results.enumerated()), id: \.element.id) { index, result in
                                SearchResultRow(
                                    result: result,
                                    query: snapshot.query,
                                    isSelected: index == snapshot.selectedIndex,
                                    onSelect: { [viewModel] in viewModel.select(index) },
                                    onOpen: { [viewModel] in
                                        viewModel.select(index)
                                        viewModel.confirmSelection()
                                    }
                                )
                                .id(result.id)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: snapshot.selectedIndex) { _, index in
                        guard snapshot.results.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(snapshot.results[index].id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(_ snapshot: SearchSnapshot) -> some View {
        HStack(spacing: 12) {
            hint("↑↓", "选择")
            hint("↩", "打开")
            hint("esc", "关闭")
            Spacer()
            if let status = snapshot.statusMessage {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if !snapshot.results.isEmpty {
                Text("\(snapshot.results.count) 条结果")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 右列（详情）

    @ViewBuilder
    private func previewColumn(_ snapshot: SearchSnapshot) -> some View {
        if let result = snapshot.selectedResult {
            VStack(alignment: .leading, spacing: 10) {
                Text(SearchHighlight.attributed(result.title, query: snapshot.query))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if result.isPinned {
                        chip("置顶", tint: .orange)
                    }
                    if result.isFavorite {
                        chip("收藏", tint: .pink)
                    }
                    chip(result.matchLabel, tint: result.isSemanticMatch ? .indigo : .accentColor)
                    if let category = result.category {
                        chip(category, tint: .blue)
                    }
                    // 形态 tag 固定跟随；其后是内容关键词 tag
                    ForEach(Array(result.displayTags.prefix(5).enumerated()), id: \.offset) { index, tag in
                        chip(tag, tint: index == 0 ? Color.teal : .gray)
                    }
                }

                metaLine(result)

                if let summary = result.summary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SearchOrganizationEditor(
                    result: result,
                    availableCategories: snapshot.availableCategories,
                    onSave: { [viewModel] organization in
                        viewModel.saveOrganization(organization)
                    }
                )
                .id(result.id)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let previewKind = SearchPreviewKind.resolve(result)
                        if previewKind.showsMediaPane, let fileURL = result.localFileURL {
                            SearchRichPreview(kind: previewKind, fileURL: fileURL)
                        }

                        Text(SearchHighlight.attributed(previewText(result), query: snapshot.query))
                            .font(.system(size: 11.5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 8)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Button("打开") { [viewModel] in
                        Task { @MainActor in viewModel.confirmSelection() }
                    }
                    .disabled(!result.defaultAction.isEnabled)

                    Button("复制") { [viewModel] in
                        Task { @MainActor in viewModel.copySelection() }
                    }

                    Button("重新总结") { [viewModel] in
                        Task { @MainActor in viewModel.resummarizeSelection() }
                    }
                    .disabled(snapshot.isBusy)

                    if result.hasLocalFile {
                        Button("预览") { [viewModel] in
                            Task { @MainActor in viewModel.quickLookSelection() }
                        }
                        Button("访达") { [viewModel] in
                            Task { @MainActor in viewModel.revealSelectionInFinder() }
                        }
                    }

                    Spacer()

                    Button("删除", role: .destructive) { [viewModel] in
                        Task { @MainActor in viewModel.deleteSelection() }
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            placeholder(icon: "text.magnifyingglass", text: "选中条目后在这里查看详情")
        }
    }

    private func previewText(_ result: KnowledgeSearchResult) -> String {
        if let body = result.previewBody,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        if let file = result.localFileURL {
            return LocalFilePreview.summary(for: file)
        }
        if let sourceURL = result.sourceURL {
            return "来源链接：\(sourceURL.absoluteString)\n\n该条目还没有可展示的正文，可点击「打开」访问来源。"
        }
        return "（该条目还没有正文内容）"
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint.opacity(0.16))
            )
            .foregroundStyle(tint)
    }

    private func metaLine(_ result: KnowledgeSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let sourceURL = result.sourceURL {
                Text(sourceURL.host() ?? sourceURL.absoluteString)
            } else if let file = result.localFileURL {
                Text(file.lastPathComponent)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
}

/// 单条结果行。
struct SearchResultRow: View {
    let result: KnowledgeSearchResult
    let query: String
    let isSelected: Bool
    let onSelect: @MainActor () -> Void
    let onOpen: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            let previewKind = SearchPreviewKind.resolve(result)
            if previewKind.showsMediaPane, result.localFileURL != nil {
                SearchResultThumbnail(kind: previewKind, fileURL: result.localFileURL)
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(highlighted(result.title))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if let snippet = result.snippet ?? result.summary, !snippet.isEmpty {
                    Text(highlighted(snippet))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text(result.resourceTypeTag)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.teal.opacity(0.16))
                        )
                        .foregroundStyle(Color.teal)
                    Text(metaSummary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.secondary.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task { @MainActor in onOpen() }
        }
        .onTapGesture {
            Task { @MainActor in onSelect() }
        }
    }

    private var iconName: String {
        switch result.contentType {
        case .image: "photo"
        case .video: "film"
        case .documentPDF: "doc.richtext"
        case .webLink: "link"
        case .richHTML: "text.alignleft"
        case .plainText: "text.quote"
        case .genericFile: "doc"
        }
    }

    private var metaSummary: String {
        var parts: [String] = [result.matchLabel]
        if result.isPinned { parts.append("置顶") }
        if result.isFavorite { parts.append("收藏") }
        if let category = result.category { parts.append(category) }
        // 内容关键词（形态 tag 已单独芯片展示）
        if !result.tags.isEmpty {
            parts.append(result.tags.prefix(3).joined(separator: " "))
        }
        parts.append(result.createdAt.formatted(date: .numeric, time: .omitted))
        return parts.joined(separator: " · ")
    }

    /// 选中行为浅色 accent 底，关键词高亮保持黄底可读。
    private func highlighted(_ text: String) -> AttributedString {
        SearchHighlight.attributed(
            text,
            query: query,
            highlightBackground: Color.yellow.opacity(0.45),
            highlightForeground: nil
        )
    }
}
