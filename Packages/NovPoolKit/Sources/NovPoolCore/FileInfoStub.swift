import Foundation

/// Generated file-info preview written when a capture has no readable body.
///
/// It is not source text. Summarize must not send it to a model, and "fill missing summaries"
/// must not treat it as a body.
public enum FileInfoStub {
    /// Sentence shared by the staging preview and the search-detail fallback.
    public static let marker = "The original file is saved in the NovPool staging directory."

    /// True when `text` is only the short generated file card, not an article or OCR transcript.
    public static func isOnlyStub(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("## File info"), trimmed.contains(marker) else { return false }
        return trimmed.count < 600
    }
}
