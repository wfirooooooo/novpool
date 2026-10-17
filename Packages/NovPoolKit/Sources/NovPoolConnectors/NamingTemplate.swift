import Foundation
import NovPoolCore

/// 命名模板渲染：`{Category}/{YYYY}-{MM}/{Title}.{ext}`。
///
/// 纯函数实现，便于单测；同时负责路径安全清洗（剥离 `/`、控制字符与前后空白）。
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
            "Category": Self.sanitize(payload.aiCategory ?? "未分类"),
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

        // 模板未包含扩展名时补上，避免云端出现无后缀文件。
        if !rendered.lowercased().hasSuffix(".\(values["ext"]!.lowercased())") {
            rendered += ".\(values["ext"]!)"
        }
        return Self.sanitizePath(rendered)
    }

    /// 单个路径分段的清洗。
    static func sanitize(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = String(stripped.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        })
        let collapsed = filtered.replacingOccurrences(of: "  ", with: " ")
        return collapsed.isEmpty ? "未命名" : String(collapsed.prefix(120))
    }

    /// 整体相对路径清洗：丢弃空段与 `..`，防止越权写出挂载目录。
    static func sanitizePath(_ raw: String) -> String {
        let segments = raw
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitize(String($0)) }
            .filter { $0 != "." && $0 != ".." }
        return segments.isEmpty ? "未命名.dat" : segments.joined(separator: "/")
    }
}
