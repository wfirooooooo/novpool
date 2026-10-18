import Foundation

/// 本机 llama.cpp（`llama-server`）的配置。
///
/// 主路径与 Ollama 一致：填写 OpenAI 兼容 **Base URL**（默认 `http://127.0.0.1:8080/v1`）。
/// 可选：由 NovPool 代为启动 `llama-server`，或按提示在终端自行启动。
public struct LocalLLMConfiguration: Sendable, Equatable, Codable {
    /// OpenAI 兼容接口地址，例如 `http://127.0.0.1:8080/v1`。
    public var apiBaseURL: String
    public var binaryPath: String
    public var modelPath: String
    public var port: Int
    /// 上下文长度（`-c`）；0 表示用 llama-server 默认值。
    public var contextSize: Int
    /// 透传给 llama-server 的额外参数，按空白切分。
    public var extraArguments: String

    public static let defaultPort = 8080
    public static let defaultAPIBaseURL = "http://127.0.0.1:8080/v1"

    /// 设置面板提示：安装与目录约定。
    public static let setupHint =
        "常见安装：brew install llama.cpp → /opt/homebrew/bin/llama-server；.gguf 可放在 ~/Models/。也可用下方命令自行启动，再把 Base URL 指过去。"

    /// 常见 llama-server 路径（按优先级）。
    public static let commonBinaryCandidates: [String] = [
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
        "\(NSHomeDirectory())/.local/bin/llama-server",
    ]

    /// 返回本机已存在的第一个可执行 llama-server 路径。
    public static func firstExistingBinaryPath(fileManager: FileManager = .default) -> String? {
        commonBinaryCandidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// 返回 ~/Models 下第一个 .gguf（若目录存在）。
    public static func firstExistingModelPath(fileManager: FileManager = .default) -> String? {
        let modelsDir = URL(filePath: NSHomeDirectory()).appending(path: "Models")
        guard let files = try? fileManager.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        return files
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first?
            .path(percentEncoded: false)
    }

    public init(
        apiBaseURL: String = LocalLLMConfiguration.defaultAPIBaseURL,
        binaryPath: String = "",
        modelPath: String = "",
        port: Int = LocalLLMConfiguration.defaultPort,
        contextSize: Int = 0,
        extraArguments: String = ""
    ) {
        self.apiBaseURL = apiBaseURL
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.port = port
        self.contextSize = contextSize
        self.extraArguments = extraArguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        binaryPath = try container.decodeIfPresent(String.self, forKey: .binaryPath) ?? ""
        modelPath = try container.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        contextSize = try container.decodeIfPresent(Int.self, forKey: .contextSize) ?? 0
        extraArguments = try container.decodeIfPresent(String.self, forKey: .extraArguments) ?? ""
        if let stored = try container.decodeIfPresent(String.self, forKey: .apiBaseURL),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiBaseURL = stored
        } else {
            apiBaseURL = "http://127.0.0.1:\((1...65535).contains(port) ? port : Self.defaultPort)/v1"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case apiBaseURL, binaryPath, modelPath, port, contextSize, extraArguments
    }

    /// 请求用的 OpenAI 兼容根地址。
    public var baseURL: URL {
        let trimmed = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url
        }
        return URL(string: "http://127.0.0.1:\(clampedPort)/v1")!
    }

    /// 按当前端口刷新默认形态的 Base URL（用户改端口后同步）。
    public mutating func syncAPIBaseURLFromPort() {
        apiBaseURL = "http://127.0.0.1:\(clampedPort)/v1"
    }

    /// 请求里使用的模型名：llama-server 只服务已加载的模型，用文件名即可。
    public var modelName: String {
        let name = URL(filePath: modelPath).deletingPathExtension().lastPathComponent
        return name.isEmpty ? "local-model" : name
    }

    public var clampedPort: Int {
        (1...65535).contains(port) ? port : Self.defaultPort
    }

    /// 能否由 NovPool 代为启动：两个路径都不能空。
    public var validationMessage: String? {
        if binaryPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return "请选择 llama-server 可执行文件路径（或仅填写 Base URL，在终端自行启动）"
        }
        if modelPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return "请选择 .gguf 模型文件"
        }
        if !(1...65535).contains(port) {
            return "端口需要在 1～65535 之间"
        }
        return nil
    }

    public var isValid: Bool { validationMessage == nil }

    /// 仅校验 Base URL 是否可连（不要求本机二进制）。
    public var apiBaseURLValidationMessage: String? {
        let trimmed = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "请填写 Base URL，例如 \(Self.defaultAPIBaseURL)" }
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            return "Base URL 无效，示例：\(Self.defaultAPIBaseURL)"
        }
        return nil
    }

    /// 组装 llama-server 启动参数。
    public func arguments() -> [String] {
        var result = [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", String(clampedPort),
        ]
        if contextSize > 0 {
            result.append(contentsOf: ["--ctx-size", String(contextSize)])
        }
        let extra = extraArguments
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        return result + extra
    }

    /// 终端启动命令提示（可复制）。路径含空格时加引号。
    public var suggestedLaunchCommand: String {
        let binary = shellQuote(binaryPath.isEmpty ? "/opt/homebrew/bin/llama-server" : binaryPath)
        let model = shellQuote(modelPath.isEmpty ? "~/Models/your-model.gguf" : modelPath)
        var parts = [
            binary,
            "--model", model,
            "--host", "127.0.0.1",
            "--port", String(clampedPort),
        ]
        if contextSize > 0 {
            parts.append(contentsOf: ["--ctx-size", String(contextSize)])
        }
        let extra = extraArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            parts.append(extra)
        }
        return parts.joined(separator: " ")
    }

    private func shellQuote(_ path: String) -> String {
        if path.contains(" ") || path.contains("'") {
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return path
    }
}
