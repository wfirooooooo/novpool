import Foundation

/// 本机 llama.cpp（`llama-server`）的启动配置。
///
/// `llama-server` 暴露 OpenAI 兼容接口（`/v1/chat/completions`），因此启动成功后
/// 只要把 AI 的 base URL 指向它，摘要/分类/标签这条链路就完全跑在本机，不出网。
public struct LocalLLMConfiguration: Sendable, Equatable, Codable {
    public var binaryPath: String
    public var modelPath: String
    public var port: Int
    /// 上下文长度（`-c`）；0 表示用 llama-server 默认值。
    public var contextSize: Int
    /// 透传给 llama-server 的额外参数，按空白切分。
    public var extraArguments: String

    public static let defaultPort = 8080

    public init(
        binaryPath: String = "",
        modelPath: String = "",
        port: Int = LocalLLMConfiguration.defaultPort,
        contextSize: Int = 0,
        extraArguments: String = ""
    ) {
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.port = port
        self.contextSize = contextSize
        self.extraArguments = extraArguments
    }

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(clampedPort)/v1")!
    }

    /// 请求里使用的模型名：llama-server 只服务已加载的模型，用文件名即可。
    public var modelName: String {
        let name = URL(filePath: modelPath).deletingPathExtension().lastPathComponent
        return name.isEmpty ? "local-model" : name
    }

    public var clampedPort: Int {
        (1...65535).contains(port) ? port : Self.defaultPort
    }

    /// 能否启动：两个路径都不能空。
    public var validationMessage: String? {
        if binaryPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return "请选择 llama-server 可执行文件路径"
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
}
