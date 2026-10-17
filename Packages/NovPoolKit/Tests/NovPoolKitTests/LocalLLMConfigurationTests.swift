import Foundation
import NovPoolCore
import Testing

@Suite("本机 llama.cpp 配置")
struct LocalLLMConfigurationTests {
    @Test("启动参数：模型、回环地址、端口按序拼装")
    func arguments() {
        let config = LocalLLMConfiguration(
            binaryPath: "/opt/homebrew/bin/llama-server",
            modelPath: "/models/qwen2.5-7b-instruct-q4.gguf",
            port: 8081
        )
        #expect(config.arguments() == [
            "--model", "/models/qwen2.5-7b-instruct-q4.gguf",
            "--host", "127.0.0.1",
            "--port", "8081",
        ])
    }

    @Test("上下文长度与额外参数追加在后面")
    func contextAndExtraArguments() {
        let config = LocalLLMConfiguration(
            binaryPath: "/bin/llama-server",
            modelPath: "/m.gguf",
            port: 9000,
            contextSize: 8192,
            extraArguments: "  --threads 8   --n-gpu-layers 99 "
        )
        let arguments = config.arguments()
        #expect(arguments.contains("--ctx-size"))
        #expect(arguments.contains("8192"))
        #expect(arguments.suffix(4) == ["--threads", "8", "--n-gpu-layers", "99"])
    }

    @Test("OpenAI 兼容地址与模型名")
    func baseURLAndModelName() {
        let config = LocalLLMConfiguration(
            binaryPath: "/bin/llama-server",
            modelPath: "/models/Llama-3.2-3B-Instruct-Q5.gguf",
            port: 8080
        )
        #expect(config.baseURL.absoluteString == "http://127.0.0.1:8080/v1")
        #expect(config.modelName == "Llama-3.2-3B-Instruct-Q5")
    }

    @Test("端口越界时回退默认值，不会生成非法参数")
    func portClamping() {
        var config = LocalLLMConfiguration(binaryPath: "/bin/x", modelPath: "/m.gguf", port: 0)
        #expect(config.clampedPort == LocalLLMConfiguration.defaultPort)
        #expect(config.arguments().contains(String(LocalLLMConfiguration.defaultPort)))
        #expect(config.validationMessage?.contains("端口") == true)

        config.port = 70000
        #expect(config.clampedPort == LocalLLMConfiguration.defaultPort)
    }

    @Test("路径缺失时给出可读的校验提示")
    func validation() {
        #expect(LocalLLMConfiguration().validationMessage?.contains("llama-server") == true)
        #expect(LocalLLMConfiguration(binaryPath: "/bin/x").validationMessage?.contains("gguf") == true)
        #expect(LocalLLMConfiguration(binaryPath: "/bin/x", modelPath: "/m.gguf").isValid)
    }

    @Test("默认安装提示与常见二进制候选路径")
    func setupHints() {
        #expect(LocalLLMConfiguration.setupHint.contains("brew install"))
        #expect(LocalLLMConfiguration.commonBinaryCandidates.contains("/opt/homebrew/bin/llama-server"))
    }
}
