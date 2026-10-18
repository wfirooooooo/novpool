import Foundation
import NovPoolCore
import Testing

@Suite("Local llama.cpp configuration")
struct LocalLLMConfigurationTests {
    @Test("Startup parameters: model, loopback address, port assembled in order")
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

    @Test("Context length and additional parameters are appended at the back")
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

    @Test("OpenAI compatible address and model name")
    func baseURLAndModelName() {
        let config = LocalLLMConfiguration(
            binaryPath: "/bin/llama-server",
            modelPath: "/models/Llama-3.2-3B-Instruct-Q5.gguf",
            port: 8080
        )
        #expect(config.baseURL.absoluteString == "http://127.0.0.1:8080/v1")
        #expect(config.modelName == "Llama-3.2-3B-Instruct-Q5")
    }

    @Test("You can directly fill in the Base URL; changing the port can synchronize the default URL")
    func apiBaseURLOverrideAndSync() {
        var config = LocalLLMConfiguration(apiBaseURL: "http://127.0.0.1:9090/v1", port: 8080)
        #expect(config.baseURL.absoluteString == "http://127.0.0.1:9090/v1")
        config.port = 9090
        config.syncAPIBaseURLFromPort()
        #expect(config.apiBaseURL == "http://127.0.0.1:9090/v1")
        #expect(config.apiBaseURLValidationMessage == nil)
        config.apiBaseURL = "not-a-url"
        #expect(config.apiBaseURLValidationMessage != nil)
    }

    @Test("Provide a copyable terminal startup command prompt")
    func suggestedLaunchCommand() {
        let config = LocalLLMConfiguration(
            binaryPath: "/opt/homebrew/bin/llama-server",
            modelPath: "/models/qwen.gguf",
            port: 8081,
            contextSize: 4096,
            extraArguments: "--n-gpu-layers 99"
        )
        let command = config.suggestedLaunchCommand
        #expect(command.contains("/opt/homebrew/bin/llama-server"))
        #expect(command.contains("--model /models/qwen.gguf"))
        #expect(command.contains("--port 8081"))
        #expect(command.contains("--ctx-size 4096"))
        #expect(command.contains("--n-gpu-layers 99"))
    }

    @Test("When the port is out of range, it falls back to the default value and will not generate illegal parameters.")
    func portClamping() {
        var config = LocalLLMConfiguration(binaryPath: "/bin/x", modelPath: "/m.gguf", port: 0)
        #expect(config.clampedPort == LocalLLMConfiguration.defaultPort)
        #expect(config.arguments().contains(String(LocalLLMConfiguration.defaultPort)))
        #expect(config.validationMessage?.contains("Port") == true)

        config.port = 70000
        #expect(config.clampedPort == LocalLLMConfiguration.defaultPort)
    }

    @Test("Provide a readable validation prompt when the path is missing")
    func validation() {
        #expect(LocalLLMConfiguration().validationMessage?.contains("llama-server") == true)
        #expect(LocalLLMConfiguration(binaryPath: "/bin/x").validationMessage?.contains("gguf") == true)
        #expect(LocalLLMConfiguration(binaryPath: "/bin/x", modelPath: "/m.gguf").isValid)
    }

    @Test("Default installation prompts and common binary candidate paths")
    func setupHints() {
        #expect(LocalLLMConfiguration.setupHint.contains("brew install"))
        #expect(LocalLLMConfiguration.commonBinaryCandidates.contains("/opt/homebrew/bin/llama-server"))
    }
}
