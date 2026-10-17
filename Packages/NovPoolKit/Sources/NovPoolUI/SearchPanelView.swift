import NovPoolCore
import NovPoolStorage
import SwiftUI

/// 检索面板内容视图：左侧列表 + 右侧详情。
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
        HStack(spacing: 0) {
            listColumn(snapshot)
                .frame(minWidth: 420)
            Divider()
            previewColumn(snapshot)
                .frame(width: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
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
                    // 这些闭包在 @MainActor 上下文里创建、参数类型也是 @MainActor，
                    // 因此体内访问视图模型不需要（也不会被插入）运行时隔离检查。
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
            .padding(.vertical, 14)

            Divider()

            resultList(snapshot)

            Divider()
            footer(snapshot)
        }
    }

    @ViewBuilder
    private func resultList(_ snapshot: SearchSnapshot) -> some View {
        switch snapshot.phase {
        case .empty:
            placeholder(icon: "tray", text: "没有匹配的条目")
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
            if !snapshot.results.isEmpty {
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
                Text(result.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    chip(result.matchLabel, tint: result.isSemanticMatch ? .purple : .accentColor)
                    if let category = result.category {
                        chip(category, tint: .blue)
                    }
                    ForEach(result.tags.prefix(4), id: \.self) { tag in
                        chip(tag, tint: .gray)
                    }
                }

                metaLine(result)

                if let summary = result.summary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                ScrollView {
                    Text(previewText(result))
                        .font(.system(size: 11.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
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
                    Spacer()
                    if result.hasLocalFile {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .help("本地暂存文件已就位")
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
            return "文件已保存：\(file.lastPathComponent)\n\n暂时无法提取文本内容，可点击「打开」查看原始文件。"
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
    let isSelected: Bool
    /// 手势/点按闭包签名是非隔离的，因此这里不直接调用 `@MainActor` 回调，
    /// 而是用 `Task` 跳回主 actor 调用（延迟一帧，用户无感知）。
    let onSelect: @MainActor () -> Void
    let onOpen: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if let snippet = result.snippet ?? result.summary, !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(2)
                }
                // 先拼成一个字符串再交给 Text：混着条件分支的 Text 拼接会让类型检查爆炸。
                Text(metaSummary)
                .font(.system(size: 9.5))
                .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.75))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
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

    /// 行内元信息：命中方式 · 分类 · 标签 · 日期。
    private var metaSummary: String {
        var parts: [String] = [result.matchLabel]
        if let category = result.category { parts.append(category) }
        if !result.tags.isEmpty {
            parts.append(result.tags.prefix(3).joined(separator: " "))
        }
        parts.append(result.createdAt.formatted(date: .numeric, time: .omitted))
        return parts.joined(separator: " · ")
    }
}
