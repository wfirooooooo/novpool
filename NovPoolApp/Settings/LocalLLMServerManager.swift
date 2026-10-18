import Foundation
import NovPoolCore

/// Starts / stops a local llama.cpp server process.
///
/// Only responsible for bringing llama-server up / down / retaining output for debugging.
/// Launch arguments and validation live in the testable `LocalLLMConfiguration`.
@MainActor
@Observable
final class LocalLLMServerManager {
    private static let maximumLogLines = 40

    var configuration: LocalLLMConfiguration {
        didSet { persist() }
    }
    private(set) var isRunning = false
    private(set) var recentOutput: [String] = []
    private(set) var lastError: String?

    private var process: Process?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "novpool.llama.config"),
           let stored = try? JSONDecoder().decode(LocalLLMConfiguration.self, from: data) {
            configuration = stored
        } else {
            configuration = LocalLLMConfiguration()
        }
    }

    var isRunningState: Bool { isRunning }

    /// Start the local model server. Returns nil on success, otherwise a readable reason.
    func start() -> String? {
        if let process, process.isRunning { return nil }
        if let problem = configuration.validationMessage { return problem }

        let binary = URL(filePath: configuration.binaryPath)
        guard FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)) else {
            return "llama-server executable not found: \(configuration.binaryPath)"
        }
        let model = URL(filePath: configuration.modelPath)
        guard FileManager.default.fileExists(atPath: model.path(percentEncoded: false)) else {
            return "Model file not found: \(configuration.modelPath)"
        }

        let task = Process()
        task.executableURL = binary
        task.arguments = configuration.arguments()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.append(text) }
        }
        task.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.append("llama-server exited (code \(finished.terminationStatus))")
                self?.process = nil
            }
        }

        do {
            try task.run()
        } catch {
            return "Failed to start: \(error.localizedDescription)"
        }
        process = task
        isRunning = true
        lastError = nil
        recentOutput.removeAll()
        append("Started: \(binary.lastPathComponent) \(configuration.arguments().joined(separator: " "))")
        return nil
    }

    func stop() {
        guard let process, process.isRunning else {
            isRunning = false
            return
        }
        process.terminate()
        append("Requested stop of llama-server")
    }

    /// Probe whether the OpenAI-compatible API is ready.
    func probe() async -> String {
        var request = URLRequest(url: configuration.baseURL.appending(path: "models"))
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return "API returned HTTP \(status)" }
            let text = String(decoding: data.prefix(200), as: UTF8.self)
            return "Connected: \(text)"
        } catch {
            return "Connection failed: \(error.localizedDescription)"
        }
    }

    private func append(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        recentOutput.append(contentsOf: lines)
        if recentOutput.count > Self.maximumLogLines {
            recentOutput.removeFirst(recentOutput.count - Self.maximumLogLines)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: "novpool.llama.config")
    }
}
