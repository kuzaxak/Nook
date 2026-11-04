// Licensed under GPL-3.0. See LICENSE.
//
//  AnthropicProvider.swift
//  Nook
//
//  Anthropic Messages API provider implementation
//

import Foundation
import NookSettings

struct AnthropicProvider: AIProviderProtocol {
    static let apiVersion = "2026-10-21"

    let apiKey: String
    let baseURL: String

    init(apiKey: String, baseURL: String = "https://api.anthropic.com") {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    func sendMessage(
        messages: [AIMessage],
        model: String,
        config: AIGenerationConfig,
        tools: [AIToolDefinition],
        onStream: @escaping @Sendable (String) -> Void
    ) async throws -> AIResponse {
        guard !apiKey.isEmpty else { throw AIProviderError.invalidAPIKey }

        var request = Self.request("messages", baseURL: baseURL, apiKey: apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Without streaming the API sends nothing until the reply is complete; Anthropic's SDKs wait 10 minutes.
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(messages: messages, model: model, config: config, tools: tools)
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw Self.failure(status: httpResponse.statusCode, body: data)
        }

        return try Self.parseResponse(data)
    }

    /// A request for `path` under the API's `/v1`, carrying the key and the API version.
    static func request(_ path: String, baseURL: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)/v1/\(path)")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    static func requestBody(
        messages: [AIMessage],
        model: String,
        config: AIGenerationConfig,
        tools: [AIToolDefinition]
    ) -> [String: Any] {
        var turns: [[String: Any]] = []

        for message in messages {
            let blocks: [[String: Any]]
            switch message.role {
            case .system:
                continue
            case .user:
                blocks = textBlocks(message.content)
            case .assistant:
                if let saved = message.providerContent,
                   let replay = (try? JSONSerialization.jsonObject(with: saved)) as? [[String: Any]] {
                    blocks = replay
                } else {
                    blocks = textBlocks(message.content) + message.toolCalls.map { toolCall in
                        ["type": "tool_use", "id": toolCall.id, "name": toolCall.name, "input": toolCall.arguments]
                    }
                }
            case .tool:
                blocks = message.toolResults.map { result in
                    var block: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": result.toolCallId,
                        "content": result.content
                    ]
                    if result.isError {
                        block["is_error"] = true
                    }
                    return block
                }
            }

            guard !blocks.isEmpty else { continue }
            let role = message.role == .assistant ? "assistant" : "user"
            if let last = turns.indices.last, turns[last]["role"] as? String == role,
               let earlier = turns[last]["content"] as? [[String: Any]] {
                turns[last]["content"] = earlier + blocks
            } else {
                turns.append(["role": role, "content": blocks])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": config.maxTokens,
            "messages": turns
        ]

        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        if !system.isEmpty {
            body["system"] = system
        }

        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                // The API requires an object schema, and an MCP server may send none.
                var schema = tool.parameters
                schema["type"] = schema["type"] ?? "object"
                return ["name": tool.name, "description": tool.description, "input_schema": schema]
            }
        }

        return body
    }

    /// The API rejects a text block that holds only whitespace.
    private static func textBlocks(_ text: String) -> [[String: Any]] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [["type": "text", "text": text]]
    }

    static func parseResponse(_ data: Data) throws -> AIResponse {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse
        }

        let stopReason = json["stop_reason"] as? String ?? ""
        if stopReason == "refusal" {
            throw AIProviderError.refused
        }

        var text = ""
        var toolCalls: [AIToolCall] = []
        for block in blocks {
            switch block["type"] as? String ?? "" {
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                toolCalls.append(AIToolCall(id: id, name: name, arguments: block["input"] as? [String: Any] ?? [:]))
            default:
                break
            }
        }

        let finishReason: AIFinishReason
        switch stopReason {
        case "tool_use": finishReason = toolCalls.isEmpty ? .stop : .toolCalls
        case "max_tokens", "model_context_window_exceeded": finishReason = .maxTokens
        default: finishReason = .stop
        }

        var usage: AIUsage?
        if let usageData = json["usage"] as? [String: Any] {
            let prompt = usageData["input_tokens"] as? Int ?? 0
            let completion = usageData["output_tokens"] as? Int ?? 0
            usage = AIUsage(promptTokens: prompt, completionTokens: completion, totalTokens: prompt + completion)
        }

        return AIResponse(
            content: text,
            toolCalls: toolCalls,
            citations: [],
            usage: usage,
            finishReason: finishReason,
            providerContent: try JSONSerialization.data(withJSONObject: blocks)
        )
    }

    /// The error for a reply other than 200, worded from the API's own error message when it sent one.
    static func failure(status: Int, body: Data) -> AIProviderError {
        if status == 429 {
            return .rateLimited
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        return .httpError(status, message ?? String(data: body, encoding: .utf8) ?? "Unknown error")
    }

    /// The model list from `GET /v1/models`, in the API's newest-first order.
    static func models(from data: Data, providerId: String) throws -> [AIModelConfig] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse
        }
        let defaults = AIModelCapabilities()
        return list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return AIModelConfig(
                id: id,
                displayName: entry["display_name"] as? String ?? id,
                providerId: providerId,
                capabilities: AIModelCapabilities(
                    toolCalling: true,
                    contextWindow: entry["max_input_tokens"] as? Int ?? defaults.contextWindow,
                    maxOutput: entry["max_tokens"] as? Int ?? defaults.maxOutput
                )
            )
        }
    }
}
