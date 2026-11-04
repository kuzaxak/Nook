// Licensed under GPL-3.0. See LICENSE.
//
//  HostedAIProvidersCheck.swift
//  Nook
//
//  What Nook sends to Anthropic's Messages API and reads back, and how the OpenAI and Anthropic
//  model lists parse. Compiles the shipped sources into one module named NookSettings, so their
//  `import NookSettings` only warns:
//
//    swiftc -module-name NookSettings \
//           Packages/NookSettings/Sources/NookSettings/AIModels.swift \
//           Packages/NookSettings/Sources/NookSettings/MCPServerConfig.swift \
//           Nook/Managers/AIManager/AIProvider.swift \
//           Nook/Managers/AIManager/Providers/OpenAICompatibleProvider.swift \
//           Nook/Managers/AIManager/Providers/AnthropicProvider.swift \
//           scripts/tests/HostedAIProvidersCheck.swift -o /tmp/hosted-ai-check && /tmp/hosted-ai-check
//

import Foundation

/// The real type lives in the sidebar's SwiftUI file, which this check does not compile.
struct URLCitation: Equatable {}

@main
struct HostedAIProvidersCheck {
    static func main() {
        requestBody()
        replayedTurn()
        responses()
        failures()
        modelLists()
        print("HostedAIProvidersCheck passed")
    }

    static func requestBody() {
        let calls = [
            AIToolCall(id: "toolu_1", name: "getTabList"),
            AIToolCall(id: "toolu_2", name: "searchInPage", arguments: ["query": "price"])
        ]
        let messages = [
            AIMessage(role: .system, content: "You are Nook."),
            AIMessage(role: .user, content: "Earlier question"),
            AIMessage(role: .assistant, content: " \n"),
            AIMessage(role: .user, content: "Which tabs?"),
            AIMessage(role: .assistant, content: "Checking.", toolCalls: calls),
            AIMessage(role: .tool, content: "", toolResults: [
                AIToolResult(toolCallId: "toolu_1", toolName: "getTabList", content: "<t>2 tabs</t>"),
                AIToolResult(toolCallId: "toolu_2", toolName: "searchInPage", content: "not found", isError: true)
            ])
        ]
        let search = AIToolDefinition(
            name: "searchInPage",
            description: "Find text on the page",
            parameters: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]
        )
        let schemaless = AIToolDefinition(name: "mcp_ping_1a2b", description: "Ping", parameters: [:])
        let config = AIGenerationConfig(temperature: 0.7, maxTokens: 2048, systemPrompt: "not this one")

        let body = AnthropicProvider.requestBody(messages: messages, model: "claude-opus-5-5", config: config, tools: [search, schemaless])
        precondition(JSONSerialization.isValidJSONObject(body))
        precondition(body["model"] as? String == "claude-opus-5-5")
        precondition(body["max_tokens"] as? Int == 16_384, "thinking shares max_tokens, so a low setting is raised")
        let roomy = AnthropicProvider.requestBody(messages: messages, model: "claude-opus-5-5", config: AIGenerationConfig(maxTokens: 32_000), tools: [])
        precondition(roomy["max_tokens"] as? Int == 32_000)
        precondition(body["system"] as? String == "You are Nook.", "the system turn goes in the top-level field")
        precondition(body["temperature"] == nil, "the API version Nook sends rejects sampling parameters")

        let turns = body["messages"] as! [[String: Any]]
        precondition(turns.map { $0["role"] as! String } == ["user", "assistant", "user"], "blank replies drop and same-role turns merge")
        precondition(same(turns[0]["content"], [
            ["type": "text", "text": "Earlier question"],
            ["type": "text", "text": "Which tabs?"]
        ]))
        precondition(same(turns[1]["content"], [
            ["type": "text", "text": "Checking."],
            ["type": "tool_use", "id": "toolu_1", "name": "getTabList", "input": [String: Any]()],
            ["type": "tool_use", "id": "toolu_2", "name": "searchInPage", "input": ["query": "price"]]
        ]))
        precondition(same(turns[2]["content"], [
            ["type": "tool_result", "tool_use_id": "toolu_1", "content": "<t>2 tabs</t>"],
            ["type": "tool_result", "tool_use_id": "toolu_2", "content": "not found", "is_error": true]
        ]), "every result of one step goes back in one user turn")

        precondition(same(body["tools"], [
            ["name": "searchInPage", "description": "Find text on the page", "input_schema": search.parameters],
            ["name": "mcp_ping_1a2b", "description": "Ping", "input_schema": ["type": "object"]]
        ]))
        let toolless = AnthropicProvider.requestBody(messages: [AIMessage(role: .user, content: "Hi")], model: "m", config: config, tools: [])
        precondition(toolless["tools"] == nil && toolless["system"] == nil)

        let request = AnthropicProvider.request("messages", baseURL: "https://api.anthropic.com", apiKey: "test-key")
        precondition(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        precondition(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        precondition(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// A tool step's reply goes back exactly as it came, thinking blocks and signatures included.
    static func replayedTurn() {
        let reply = """
        {"id":"msg_2","type":"message","role":"assistant","model":"claude-opus-5-5",
         "content":[{"type":"thinking","thinking":"","signature":"EqQBCkYIBxgCKkA="},
                    {"type":"tool_use","id":"toolu_9","name":"getTabList","input":{}}],
         "stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}}
        """
        let response = try! AnthropicProvider.parseResponse(Data(reply.utf8))
        let next = AnthropicProvider.requestBody(messages: [
            AIMessage(role: .user, content: "Which tabs?"),
            AIMessage(role: .assistant, content: response.content, toolCalls: response.toolCalls, providerContent: response.providerContent),
            AIMessage(role: .tool, content: "", toolResults: [AIToolResult(toolCallId: "toolu_9", content: "2 tabs")])
        ], model: "claude-opus-5-5", config: AIGenerationConfig(), tools: [])
        let turns = next["messages"] as! [[String: Any]]
        precondition(same(turns[1]["content"], [
            ["type": "thinking", "thinking": "", "signature": "EqQBCkYIBxgCKkA="],
            ["type": "tool_use", "id": "toolu_9", "name": "getTabList", "input": [String: Any]()]
        ]))
    }

    static func responses() {
        let toolStep = """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5",
         "content":[{"type":"thinking","thinking":"","signature":"EqQB"},
                    {"type":"text","text":"Let me look. "},
                    {"type":"tool_use","id":"toolu_a","name":"getTabList","input":{}},
                    {"type":"tool_use","id":"toolu_b","name":"searchInPage","input":{"query":"price","limit":3}}],
         "stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":120,"output_tokens":40}}
        """
        let step = try! AnthropicProvider.parseResponse(Data(toolStep.utf8))
        precondition(step.content == "Let me look. ")
        precondition(step.finishReason == .toolCalls)
        precondition(step.toolCalls.map(\.id) == ["toolu_a", "toolu_b"])
        precondition(step.toolCalls.map(\.name) == ["getTabList", "searchInPage"])
        precondition(step.toolCalls[0].arguments.isEmpty)
        precondition(step.toolCalls[1].arguments["query"] as? String == "price" && step.toolCalls[1].arguments["limit"] as? Int == 3)
        precondition(step.usage == AIUsage(promptTokens: 120, completionTokens: 40, totalTokens: 160))
        precondition(step.providerContent != nil)

        let answer = try! AnthropicProvider.parseResponse(Data("""
        {"type":"message","role":"assistant","content":[{"type":"text","text":"Two "},{"type":"text","text":"tabs."}],
         "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":2}}
        """.utf8))
        precondition(answer.content == "Two tabs." && answer.toolCalls.isEmpty && answer.finishReason == .stop)

        // A call cut off at the output cap is not run.
        let cut = try! AnthropicProvider.parseResponse(Data("""
        {"type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_c","name":"navigateToURL","input":{"url":"https://exa"}}],
         "stop_reason":"max_tokens","usage":{"input_tokens":1,"output_tokens":2}}
        """.utf8))
        precondition(cut.finishReason == .maxTokens)

        // The chat says when the output limit ended a reply, instead of a blank or cut-off answer.
        precondition(AIResponse(content: "Two tabs.", finishReason: .stop).chatText == "Two tabs.")
        let partial = AIResponse(content: "The page lists three", finishReason: .maxTokens).chatText
        precondition(partial.hasPrefix("The page lists three") && partial.count > "The page lists three".count && partial.contains("Max Output Tokens"))
        let blank = AIResponse(content: " \n", finishReason: .maxTokens).chatText
        precondition(!blank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && blank.contains("Max Output Tokens"))
        let full = try! AnthropicProvider.parseResponse(Data("""
        {"type":"message","role":"assistant","content":[{"type":"text","text":"Long"}],"stop_reason":"model_context_window_exceeded"}
        """.utf8))
        precondition(full.finishReason == .maxTokens)

        precondition(throwsError({ try AnthropicProvider.parseResponse(Data("""
        {"type":"message","role":"assistant","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}
        """.utf8)) }) { if case .refused = $0 { return true }; return false })
        precondition(throwsError({ try AnthropicProvider.parseResponse(Data("event: message_start".utf8)) }) { if case .invalidResponse = $0 { return true }; return false })
        precondition(throwsError({ try AnthropicProvider.parseResponse(Data(#"{"type":"message"}"#.utf8)) }) { if case .invalidResponse = $0 { return true }; return false })
    }

    static func failures() {
        let badKey = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_1"}"#.utf8)
        if case .invalidAPIKey = AnthropicProvider.failure(status: 401, body: badKey) {} else { preconditionFailure("401 reads as a bad key") }
        let openAIBadKey = Data(#"{"error":{"message":"Incorrect API key provided: sk-ab***yz","type":"invalid_request_error","code":"invalid_api_key"}}"#.utf8)
        if case .invalidAPIKey = OpenAICompatibleProvider.failure(status: 401, body: openAIBadKey) {} else { preconditionFailure("401 reads as a bad key") }
        if case .rateLimited = OpenAICompatibleProvider.failure(status: 429, body: Data()) {} else { preconditionFailure("429 reads as a rate limit") }
        precondition(OpenAICompatibleProvider.failure(status: 500, body: Data("upstream".utf8)).errorDescription == "HTTP 500: upstream")

        // Page translation sends the rest of a page on device only after these.
        let unreachable: [AIProviderError] = [.invalidAPIKey, .httpError(403, "forbidden"), .httpError(404, "model_not_found"), .insecureURL("http://lan")]
        precondition(unreachable.allSatisfy(\.failsEveryRequest))
        let passing: [AIProviderError] = [.rateLimited, .refused, .invalidResponse, .httpError(500, ""), .httpError(529, "Overloaded"), .httpError(400, "")]
        precondition(!passing.contains(where: \.failsEveryRequest), "a busy server or one bad request can pass")
        let limited = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your rate limit"}}"#.utf8)
        if case .rateLimited = AnthropicProvider.failure(status: 429, body: limited) {} else { preconditionFailure("429 reads as a rate limit") }
        let busy = Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)
        precondition(AnthropicProvider.failure(status: 529, body: busy).errorDescription == "HTTP 529: Overloaded")
        precondition(AnthropicProvider.failure(status: 502, body: Data("<html>Bad Gateway</html>".utf8)).errorDescription == "HTTP 502: <html>Bad Gateway</html>")
    }

    static func modelLists() {
        let anthropic = try! AnthropicProvider.models(from: Data("""
        {"data":[
          {"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-09-21T00:00:00Z",
           "max_input_tokens":1000000,"max_tokens":128000},
          {"type":"model","id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5","created_at":"2025-10-15T00:00:00Z",
           "max_input_tokens":null,"max_tokens":null}
        ],"has_more":false,"first_id":"claude-opus-5-5","last_id":"claude-haiku-4-5"}
        """.utf8), providerId: "anthropic")
        precondition(anthropic.map(\.id) == ["claude-opus-5-5", "claude-haiku-4-5"], "kept in the API's newest-first order")
        precondition(anthropic.map(\.displayName) == ["Claude Opus 5.5", "Claude Haiku 4.5"])
        precondition(anthropic.allSatisfy { $0.providerId == "anthropic" && $0.capabilities.toolCalling && !$0.isCustom })
        precondition(anthropic[0].capabilities.contextWindow == 1_000_000 && anthropic[0].capabilities.maxOutput == 128_000)
        precondition(anthropic[1].capabilities.contextWindow == AIModelCapabilities().contextWindow)

        let openAI = try! OpenAICompatibleProvider.models(from: Data("""
        {"object":"list","data":[
          {"id":"gpt-4o","object":"model","created":1715367049,"owned_by":"system"},
          {"id":"gpt-5","object":"model","created":1754425777,"owned_by":"system"},
          {"id":"o3","object":"model","created":1744225308,"owned_by":"system"}
        ]}
        """.utf8), providerId: "openai")
        precondition(openAI.map(\.id) == ["gpt-5", "o3", "gpt-4o"], "newest first")
        precondition(openAI.map(\.displayName) == openAI.map(\.id))
        precondition(openAI.allSatisfy { $0.providerId == "openai" && $0.capabilities.toolCalling && !$0.isCustom })

        let catalog = [
            "gpt-5", "gpt-5-mini", "gpt-6-luna", "GPT-4.1", "chatgpt-4o-latest", "o1", "o3-mini", "o4-mini", "o5",
            "ft:gpt-4o-mini:acme::abc123",
            "text-embedding-3-large", "tts-1", "gpt-4o-mini-tts", "whisper-1", "dall-e-3", "omni-moderation-latest",
            "gpt-image-1", "gpt-4o-realtime-preview", "gpt-4o-audio-preview", "gpt-4o-transcribe", "gpt-4o-search-preview",
            "o4-mini-deep-research", "gpt-5-pro", "o3-pro", "gpt-5-codex", "codex-mini-latest", "sora-2", "babbage-002",
            "gpt-3.5-turbo-instruct", "computer-use-preview", "omni-1"
        ]
        precondition(catalog.filter(AIProviderType.openAI.isChatModel) == [
            "gpt-5", "gpt-5-mini", "gpt-6-luna", "GPT-4.1", "chatgpt-4o-latest", "o1", "o3-mini", "o4-mini", "o5",
            "ft:gpt-4o-mini:acme::abc123"
        ], "OpenAI's list offers only models that take chat completions")
        precondition(AIProviderType.openAICompatible.isChatModel("text-embedding-nomic") && AIProviderType.openRouter.isChatModel("openai/gpt-image-1"),
                     "another server's list is taken as it comes")

        let refused = Data(#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#.utf8)
        precondition((try? AnthropicProvider.models(from: refused, providerId: "anthropic")) == nil)
        precondition((try? OpenAICompatibleProvider.models(from: refused, providerId: "openai")) == nil)
    }

    private static func same(_ value: Any?, _ expected: [[String: Any]]) -> Bool {
        guard let value else { return false }
        return (value as AnyObject).isEqual(expected as NSArray)
    }

    private static func throwsError(_ body: () throws -> Any, matching: (AIProviderError) -> Bool) -> Bool {
        do {
            _ = try body()
            return false
        } catch let error as AIProviderError {
            return matching(error)
        } catch {
            return false
        }
    }
}
