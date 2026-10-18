import AppKit
import NovPoolCore
import NovPoolStorage
import SwiftUI

/// Search panel content: list on the left, detail on the right (`HSplitView` resizable).
@MainActor
public struct SearchPanelView: View {
    private let viewModel: SearchViewModel

    public init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        // Read the snapshot in body (main actor); later closures only consume plain values.
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
        // Same as Settings Form: opaque system window background, not translucent material.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Left column

    private func listColumn(_ snapshot: SearchSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                SearchFieldView(
                    text: snapshot.query,
                    placeholder: "Search local knowledge base (title, body, OCR, tags, source)",
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
            // Resource-kind filter (web/image/video…) ≠ topic category
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Kind")
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
                    "Time",
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
                    "Topic",
                    selection: Binding(
                        get: { snapshot.filter.category ?? "" },
                        set: { [viewModel] value in
                            viewModel.setCategoryFilter(value.isEmpty ? nil : value)
                        }
                    )
                ) {
                    Text("All topics").tag("")
                    ForEach(snapshot.availableCategories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 140)
                .help("Filter by content topic, not by file type")

                filterChip(
                    "Favorite",
                    selected: snapshot.filter.favoritesOnly
                ) { [viewModel] in
                    viewModel.setFavoritesOnly(!snapshot.filter.favoritesOnly)
                }

                filterChip(
                    "Pinned",
                    selected: snapshot.filter.pinnedOnly
                ) { [viewModel] in
                    viewModel.setPinnedOnly(!snapshot.filter.pinnedOnly)
                }

                if snapshot.filter.isActive {
                    Button("Clear filters") { [viewModel] in
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
                text: snapshot.filter.isActive ? "No items match the current filters" : "No matching items"
            )
        case .failed(let message):
            placeholder(icon: "exclamationmark.triangle", text: message)
        default:
            if snapshot.results.isEmpty {
                placeholder(icon: "clock", text: snapshot.isBusy ? "Searching…" : "Nothing captured yet")
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
            hint("↑↓", "Select")
            hint("↩", "Open")
            hint("esc", "Close")
            Spacer()
            if let status = snapshot.statusMessage {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if !snapshot.results.isEmpty {
                Text("\(snapshot.results.count) results")
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

    // MARK: - Right column (detail)

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
                        chip("Pinned", tint: .orange)
                    }
                    if result.isFavorite {
                        chip("Favorite", tint: .pink)
                    }
                    chip(result.matchLabel, tint: result.isSemanticMatch ? .indigo : .accentColor)
                    if let category = result.category {
                        chip(category, tint: .blue)
                    }
                    // Kind tag is fixed first; content keyword tags follow
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
                    Button("Open") { [viewModel] in
                        Task { @MainActor in viewModel.confirmSelection() }
                    }
                    .disabled(!result.defaultAction.isEnabled)

                    Button("Copy") { [viewModel] in
                        Task { @MainActor in viewModel.copySelection() }
                    }

                    Button("Re-summarize") { [viewModel] in
                        Task { @MainActor in viewModel.resummarizeSelection() }
                    }
                    .disabled(snapshot.isBusy)

                    if result.hasLocalFile {
                        Button("Preview") { [viewModel] in
                            Task { @MainActor in viewModel.quickLookSelection() }
                        }
                        Button("Finder") { [viewModel] in
                            Task { @MainActor in viewModel.revealSelectionInFinder() }
                        }
                    }

                    Spacer()

                    Button("Delete", role: .destructive) { [viewModel] in
                        Task { @MainActor in viewModel.deleteSelection() }
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            placeholder(icon: "text.magnifyingglass", text: "Select an item to see details here")
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
            return "Source link: \(sourceURL.absoluteString)\n\nThis item has no displayable body yet. Click Open to visit the source."
        }
        return "(This item has no body content yet)"
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

/// One result row.
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
        if result.isPinned { parts.append("Pinned") }
        if result.isFavorite { parts.append("Favorite") }
        if let category = result.category { parts.append(category) }
        // Content keywords (kind tag shown as its own chip)
        if !result.tags.isEmpty {
            parts.append(result.tags.prefix(3).joined(separator: " "))
        }
        parts.append(result.createdAt.formatted(date: .numeric, time: .omitted))
        return parts.joined(separator: " · ")
    }

    /// Selected row uses a light accent fill; keyword highlights stay yellow for readability.
    private func highlighted(_ text: String) -> AttributedString {
        SearchHighlight.attributed(
            text,
            query: query,
            highlightBackground: Color.yellow.opacity(0.45),
            highlightForeground: nil
        )
    }
}
