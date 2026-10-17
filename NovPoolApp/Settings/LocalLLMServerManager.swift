import Foundation
import NovPoolCore

/// 本机 llama.cpp 服务进程的启停管理。
///
/// 只负责「把 llama-server 拉起来 / 停下来 / 把输出留下来排错」，
/// 启动参数与校验逻辑在可测的 `LocalLLMConfiguration` 里。
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

    /// 启动本机模型服务。返回 nil 表示成功，否则返回可读原因。
    func start() -> String? {
        if let process, process.isRunning { return nil }
        if let problem = configuration.validationMessage { return problem }

        let binary = URL(filePath: configuration.binaryPath)
        guard FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)) else {
            return "找不到可执行的 llama-server：\(configuration.binaryPath)"
        }
        let model = URL(filePath: configuration.modelPath)
        guard FileManager.default.fileExists(atPath: model.path(percentEncoded: false)) else {
            return "找不到模型文件：\(configuration.modelPath)"
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
                self?.append("llama-server 已退出（code \(finished.terminationStatus)）")
                self?.process = nil
            }
        }

        do {
            try task.run()
        } catch {
            return "启动失败：\(error.localizedDescription)"
        }
        process = task
        isRunning = true
        lastError = nil
        recentOutput.removeAll()
        append("已启动：\(binary.lastPathComponent) \(configuration.arguments().joined(separator: " "))")
        return nil
    }

    func stop() {
        guard let process, process.isRunning else {
            isRunning = false
            return
        }
        process.terminate()
        append("已请求停止 llama-server")
    }

    /// 探测 OpenAI 兼容接口是否就绪。
    func probe() async -> String {
        var request = URLRequest(url: configuration.baseURL.appending(path: "models"))
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return "接口返回 HTTP \(status)" }
            let text = String(decoding: data.prefix(200), as: UTF8.self)
            return "连接正常：\(text)"
        } catch {
            return "连接失败：\(error.localizedDescription)"
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
