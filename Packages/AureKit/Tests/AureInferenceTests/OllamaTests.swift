@testable import AureCore
import Foundation
import Testing
@testable import AureInference

@Suite struct OllamaTests {
    @Test func hostFollowsOllamaHost() {
        #expect(OllamaClient.defaultBaseURL(environment: [:]).absoluteString == "http://127.0.0.1:11434")
        #expect(OllamaClient.defaultBaseURL(environment: ["OLLAMA_HOST": "0.0.0.0"]).absoluteString == "http://127.0.0.1:11434")
        #expect(OllamaClient.defaultBaseURL(environment: ["OLLAMA_HOST": "127.0.0.1:8081"]).absoluteString == "http://127.0.0.1:8081")
        #expect(OllamaClient.defaultBaseURL(environment: ["OLLAMA_HOST": "localhost"]).absoluteString == "http://localhost:11434")
        #expect(OllamaClient.defaultBaseURL(environment: ["OLLAMA_HOST": "[::1]:9000"]).absoluteString == "http://[::1]:9000")
    }

    /// Text must never leave the Mac: a remote OLLAMA_HOST is ignored.
    @Test func remoteHostsAreIgnored() {
        for host in ["https://ollama.local", "192.168.1.20:11434", "example.com", "http://10.0.0.5"] {
            #expect(OllamaClient.defaultBaseURL(environment: ["OLLAMA_HOST": host]).absoluteString == "http://127.0.0.1:11434")
        }
    }

    @Test func thinkingTemplatesGetAnEmptyThinkBlock() {
        #expect(OllamaProvider.nonThinkingPrefill(template: "{{ .Prompt }}<|im_start|>assistant\n<think>\n")
            == "<think>\n\n</think>\n\n")
        #expect(OllamaProvider.nonThinkingPrefill(template: "{{ .Prompt }}<|start_header_id|>assistant") == nil)
    }

    @Test func requestBodyMapsParams() throws {
        let p = OllamaProvider(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "qwen3:4b", thinks: true,
                               prefill: "<think>\n\n</think>\n\n")
        let schema = try JSONSerialization.data(withJSONObject: ["type": "object"])
        let body = p.body(system: "sys", examples: [Prompt.Turn(user: "u1", assistant: "a1")], user: "hi",
                          jsonSchema: schema,
                          params: GenParams(temperature: 0.1, topP: 0.8, maxTokens: 64, topLogprobs: 5, banned: ["—"]))
        #expect(body["model"] as? String == "qwen3:4b")
        #expect(body["think"] as? Bool == false)
        #expect(body["logprobs"] as? Bool == true)
        #expect(body["top_logprobs"] as? Int == 5)
        #expect((body["format"] as? [String: String])?["type"] == "object")
        #expect(body["logit_bias"] == nil)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user", "assistant", "user", "assistant"])
        #expect(messages.last?["content"] == "<think>\n\n</think>\n\n")
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["num_predict"] as? Int == 64)
        #expect(options["temperature"] as? Double == 0.1)
    }

    @Test func nonThinkingModelsGetNoThinkField() {
        let p = OllamaProvider(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "llama3.2")
        let body = p.body(system: "s", examples: [], user: "u", jsonSchema: nil, params: GenParams())
        #expect(body["think"] == nil)
        #expect(body["logprobs"] == nil)
        #expect((body["messages"] as? [[String: String]])?.last?["role"] == "user")
    }

    @Test func parsesContentAndLogprobs() throws {
        let json = """
        {"message":{"role":"assistant","content":"She goes."},"done":true,
         "logprobs":[{"token":"She","logprob":-0.1,"bytes":[83,104,101],
                      "top_logprobs":[{"token":"She","logprob":-0.1,"bytes":[83,104,101]},{"token":"He","logprob":-2.5}]}]}
        """
        let c = try OllamaProvider.parse(Data(json.utf8))
        #expect(c.text == "She goes.")
        #expect(c.tokens.count == 1)
        #expect(c.tokens[0].bytes == Array("She".utf8))
        #expect(c.tokens[0].top[1].bytes == Array("He".utf8))
    }

    @Test func missingLogprobsAreEmpty() throws {
        let c = try OllamaProvider.parse(Data(#"{"message":{"content":"Fine."}}"#.utf8))
        #expect(c.text == "Fine." && c.tokens.isEmpty)
        #expect(throws: AureError.self) { try OllamaProvider.parse(Data(#"{"message":{"content":""}}"#.utf8)) }
    }

    @Test func listsModelsSortedByName() throws {
        let json = """
        {"models":[{"name":"qwen3:4b","size":2500000000,"details":{"family":"qwen3","parameter_size":"4.0B",
                    "quantization_level":"Q4_K_M"},"capabilities":["completion","thinking"]},
                   {"name":"nomic-embed-text:latest","size":274000000,"capabilities":["embedding"]},
                   {"name":"Old:latest","size":1}]}
        """
        let models = try OllamaClient.parseModels(Data(json.utf8))
        #expect(models.map(\.name) == ["nomic-embed-text:latest", "Old:latest", "qwen3:4b"])
        #expect(models.map(\.canChat) == [false, true, true])
        #expect(models[2].parameterSize == "4.0B")
    }

    @Test func errorMessageReadsOllamaErrors() {
        #expect(OllamaProvider.errorMessage(Data(#"{"error":"model 'x' not found"}"#.utf8)) == "model 'x' not found")
    }
}
