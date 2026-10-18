import Foundation
import NovPoolCore

/// Naming template rendering: `{Category}/{YYYY}-{MM}/{Title}.{ext}`.
///
/// Implemented as a pure function, making it easy to unit test; also responsible for path safety cleaning (removing `/`, control characters, and leading/trailing whitespace).
public struct NamingTemplate: Sendable {
    public static let defaultTemplate = "{Category}/{YYYY}-{MM}/{Title}.{ext}"

    public let template: String

    public init(template: String = NamingTemplate.defaultTemplate) {
        self.template = template
    }

    public func render(
        payload: NormalizedPayload,
        fileExtension: String,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let values: [String: String] = [
            "Category": Self.sanitize(payload.aiCategory ?? "Uncategorized"),
            "YYYY": String(format: "%04d", components.year ?? 0),
            "MM": String(format: "%02d", components.month ?? 0),
            "DD": String(format: "%02d", components.day ?? 0),
            "Title": Self.sanitize(payload.title),
            "ext": fileExtension.isEmpty ? "dat" : fileExtension,
        ]

        var rendered = template
        for (key, value) in values {
            rendered = rendered.replacingOccurrences(of: "{\(key)}", with: value)
        }

        // Add the extension if the template does not include it, to avoid files without suffixes appearing in the cloud.
        if !rendered.lowercased().hasSuffix(".\(values["ext"]!.lowercased())") {
            rendered += ".\(values["ext"]!)"
        }
        return Self.sanitizePath(rendered)
    }

    /// Cleaning of individual path segments.
    static func sanitize(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = String(stripped.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        })
        let collapsed = filtered.replacingOccurrences(of: "  ", with: " ")
        return collapsed.isEmpty ? "Untitled" : String(collapsed.prefix(120))
    }

    /// Overall relative path cleaning: discard empty segments and `..` to prevent unauthorized writing to the mount directory.
    static func sanitizePath(_ raw: String) -> String {
        let segments = raw
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitize(String($0)) }
            .filter { $0 != "." && $0 != ".." }
        return segments.isEmpty ? "untitled.dat" : segments.joined(separator: "/")
    }
}
