import Foundation

/// 日志与错误文案脱敏：避免 access_token / API Key 等明文落盘。
public enum SecretRedactor {
    /// 常见敏感片段：Bearer、sk-、ntn_、长 hex/base64、JSON 里的 token 字段。
    private static let patterns: [NSRegularExpression] = {
        let raw = [
            #"(?i)(bearer\s+)[a-z0-9\-._~+/]+=*"#,
            #"(?i)(access_token|refresh_token|id_token|client_secret|api[_-]?key)\s*[:=]\s*["']?[^\s"',}]+"#,
            #"\bsk-[A-Za-z0-9]{16,}\b"#,
            #"\bntn_[A-Za-z0-9]{16,}\b"#,
            #"\bya29\.[A-Za-z0-9\-._~+/]+=*\b"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    public static func redact(_ text: String) -> String {
        var result = text as NSString
        for regex in patterns {
            let range = NSRange(location: 0, length: result.length)
            result = regex.stringByReplacingMatches(
                in: result as String,
                options: [],
                range: range,
                withTemplate: "$1***"
            ) as NSString
        }
        return result as String
    }
}
