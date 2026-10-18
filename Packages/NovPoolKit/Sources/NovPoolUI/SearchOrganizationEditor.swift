import NovPoolStorage
import SwiftUI

/// 检索详情里的人工整理表单：主题分类、标签、置顶、收藏。
@MainActor
struct SearchOrganizationEditor: View {
    let result: KnowledgeSearchResult
    let availableCategories: [String]
    let onSave: @MainActor (KnowledgeOrganization) -> Void

    @State private var categoryText: String
    @State private var tagsText: String
    @State private var isPinned: Bool
    @State private var isFavorite: Bool

    init(
        result: KnowledgeSearchResult,
        availableCategories: [String],
        onSave: @escaping @MainActor (KnowledgeOrganization) -> Void
    ) {
        self.result = result
        self.availableCategories = availableCategories
        self.onSave = onSave
        _categoryText = State(initialValue: result.category ?? "")
        _tagsText = State(initialValue: result.tags.joined(separator: ", "))
        _isPinned = State(initialValue: result.isPinned)
        _isFavorite = State(initialValue: result.isFavorite)
    }

    private var draft: KnowledgeOrganization {
        KnowledgeOrganization.fromRaw(
            category: categoryText,
            tagsText: tagsText,
            isPinned: isPinned,
            isFavorite: isFavorite
        )
    }

    private var isDirty: Bool {
        draft != result.organization
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("整理")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("主题分类", text: $categoryText)
                    .textFieldStyle(.roundedBorder)
                    .help("按内容主题归类，例如技术/产品/生活；不要填图片、PDF 等格式名")
                if !availableCategories.isEmpty {
                    Picker("选用", selection: Binding(
                        get: { categoryText },
                        set: { categoryText = $0 }
                    )) {
                        Text("选用主题…").tag("")
                        ForEach(availableCategories, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }

            TextField("标签（逗号分隔，内容关键词）", text: $tagsText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 14) {
                Toggle("置顶", isOn: $isPinned)
                Toggle("收藏", isOn: $isFavorite)
                Spacer(minLength: 0)
                Button("保存") {
                    onSave(draft)
                }
                .disabled(!isDirty)
                .keyboardShortcut(.defaultAction)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .font(.system(size: 11))
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .onChange(of: result.id) { _, _ in
            categoryText = result.category ?? ""
            tagsText = result.tags.joined(separator: ", ")
            isPinned = result.isPinned
            isFavorite = result.isFavorite
        }
    }
}
