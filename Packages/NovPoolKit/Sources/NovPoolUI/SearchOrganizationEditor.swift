import NovPoolStorage
import SwiftUI

/// Manual organization form in search details: topic category, tags, pinned, favorite.
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
            Text("Organize")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Topic category", text: $categoryText)
                    .textFieldStyle(.roundedBorder)
                    .help("Classify by topic, e.g. Technology/Product/Life; do not use format names like Image or PDF")
                if !availableCategories.isEmpty {
                    Picker("Use", selection: Binding(
                        get: { categoryText },
                        set: { categoryText = $0 }
                    )) {
                        Text("Choose topic…").tag("")
                        ForEach(availableCategories, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }

            TextField("Tags (comma-separated content keywords)", text: $tagsText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 14) {
                Toggle("Pinned", isOn: $isPinned)
                Toggle("Favorite", isOn: $isFavorite)
                Spacer(minLength: 0)
                Button("Save") {
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
