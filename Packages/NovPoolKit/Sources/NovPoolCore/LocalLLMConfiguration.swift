import Foundation

/// Local llama.cpp (`llama-server`) configuration.
///
/// Same primary path as Ollama: set an OpenAI-compatible **Base URL** (default `http://127.0.0.1:8080/v1`).
/// Optionally let NovPool launch `llama-server`, or start it yourself from the terminal tip.
public struct LocalLLMConfiguration: Sendable, Equatable, Codable {
    /// OpenAI-compatible API base URL, e.g. `http://127.0.0.1:8080/v1`.
    public var apiBaseURL: String
    public var binaryPath: String
    public var modelPath: String
    public var port: Int
    /// Context length (`-c`); 0 means llama-server default.
    public var contextSize: Int
    /// Extra llama-server args, split on whitespace.
    public var extraArguments: String

    public static let defaultPort = 8080
    public static let defaultAPIBaseURL = "http://127.0.0.1:8080/v1"

    /// Settings hint: install and directory conventions.
    public static let setupHint =
        "Common install: brew install llama.cpp → /opt/homebrew/bin/llama-server; place .gguf files in ~/Models/. Or start the server yourself with the command below and point Base URL at it."

    /// Common llama-server paths (priority order).
    public static let commonBinaryCandidates: [String] = [
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
        "\(NSHomeDirectory())/.local/bin/llama-server",
    ]

    /// First existing executable llama-server path on this Mac.
    public static func firstExistingBinaryPath(fileManager: FileManager = .default) -> String? {
        commonBinaryCandidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// First .gguf under ~/Models (if the directory exists).
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

    /// OpenAI-compatible root URL used for requests.
    public var baseURL: URL {
        let trimmed = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url
        }
        return URL(string: "http://127.0.0.1:\(clampedPort)/v1")!
    }

    /// Refresh the default-shaped Base URL when the user changes the port.
    public mutating func syncAPIBaseURLFromPort() {
        apiBaseURL = "http://127.0.0.1:\(clampedPort)/v1"
    }

    /// Model name for requests: llama-server only serves the loaded model; the file name is enough.
    public var modelName: String {
        let name = URL(filePath: modelPath).deletingPathExtension().lastPathComponent
        return name.isEmpty ? "local-model" : name
    }

    public var clampedPort: Int {
        (1...65535).contains(port) ? port : Self.defaultPort
    }

    /// Whether NovPool can launch it: both paths must be set.
    public var validationMessage: String? {
        if binaryPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Choose the llama-server executable path (or only fill in Base URL and start it yourself in a terminal)"
        }
        if modelPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Choose a .gguf model file"
        }
        if !(1...65535).contains(port) {
            return "Port must be between 1 and 65535"
        }
        return nil
    }

    public var isValid: Bool { validationMessage == nil }

    /// Only validate that Base URL is usable (local binary not required).
    public var apiBaseURLValidationMessage: String? {
        let trimmed = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a Base URL, e.g.\(Self.defaultAPIBaseURL)" }
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            return "Invalid Base URL, example: \(Self.defaultAPIBaseURL)"
        }
        return nil
    }

    /// Build llama-server launch arguments.
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

    /// Copyable terminal launch hint. Quote paths that contain spaces.
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
