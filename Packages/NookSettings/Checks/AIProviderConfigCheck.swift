// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookSettings/Sources/NookSettings/AIModels.swift Packages/NookSettings/Sources/NookSettings/MCPServerConfig.swift Packages/NookSettings/Checks/AIProviderConfigCheck.swift -o /tmp/ai-provider-config && /tmp/ai-provider-config

import Foundation

@main
struct AIProviderConfigCheck {
    static func main() {
        // A config saved before OpenAI and Anthropic were providers decodes as it was.
        let saved = """
        {"providers":[
          {"id":"apple_intelligence","displayName":"Apple Intelligence","providerType":"apple_intelligence","baseURL":"","isEnabled":true,"customHeaders":{}},
          {"id":"gemini","displayName":"Google Gemini","providerType":"gemini","baseURL":"https://generativelanguage.googleapis.com/v1beta","isEnabled":true,"customHeaders":{}},
          {"id":"openrouter","displayName":"OpenRouter","providerType":"openrouter","baseURL":"https://openrouter.ai/api/v1","isEnabled":true,"customHeaders":{}},
          {"id":"ollama","displayName":"Ollama (Local)","providerType":"ollama","baseURL":"http://localhost:11434","isEnabled":true,"customHeaders":{}},
          {"id":"6B1F0C2A","displayName":"LM Studio","providerType":"openai_compatible","baseURL":"http://localhost:1234/v1","isEnabled":false,"customHeaders":{"X-Team":"a"}}
        ],
        "models":[{"id":"gemini-2.5-flash","displayName":"Gemini 2.5 Flash","providerId":"gemini","isCustom":true,
          "capabilities":{"toolCalling":true,"streaming":true,"webSearch":true,"contextWindow":128000,"maxOutput":4096}}],
        "activeProviderId":"gemini","activeModelId":"gemini-2.5-flash",
        "generationConfig":{"temperature":0.7,"maxTokens":4096,"systemPrompt":"Be brief.","streamingEnabled":true,
          "webSearchEnabled":false,"webSearchEngine":"auto","webSearchMaxResults":5,"webSearchContextSize":"medium"},
        "mcpServers":[],
        "browserToolsConfig":{"executionMode":"ask","enabledTools":["readPageContent"]}}
        """
        var config = try! JSONDecoder().decode(AIConfiguration.self, from: Data(saved.utf8))
        precondition(config.providers.map(\.providerType) == [.appleIntelligence, .gemini, .openRouter, .ollama, .openAICompatible])
        precondition(config.providers[4].customHeaders == ["X-Team": "a"] && !config.providers[4].isEnabled)
        precondition(config.activeProviderId == "gemini" && config.activeModelId == "gemini-2.5-flash")
        precondition(config.generationConfig.systemPrompt == "Be brief.")

        // The new types are stored under their own names and carry what the settings row needs.
        precondition(AIProviderType(rawValue: "openai") == .openAI)
        precondition(AIProviderType(rawValue: "anthropic") == .anthropic)
        precondition(AIProviderType.openAI.displayName == "OpenAI")
        precondition(AIProviderType.anthropic.displayName == "Anthropic")
        precondition(AIProviderType.openAI.requiresAPIKey && AIProviderType.anthropic.requiresAPIKey)
        precondition(AIProviderType.openAI.defaultBaseURL == "https://api.openai.com/v1")
        precondition(AIProviderType.anthropic.defaultBaseURL == "https://api.anthropic.com")

        // The old config gains both once, ahead of the custom provider, and keeps its choice.
        precondition(config.addMissingProviders([.openAI, .anthropic]))
        precondition(config.providers.map(\.id) == ["apple_intelligence", "gemini", "openrouter", "ollama", "openai", "anthropic", "6B1F0C2A"])
        precondition(config.providers[4].providerType == .openAI && config.providers[4].displayName == "OpenAI")
        precondition(config.providers[4].baseURL == "https://api.openai.com/v1" && config.providers[4].isEnabled)
        precondition(config.providers[5].providerType == .anthropic && config.providers[5].baseURL == "https://api.anthropic.com")
        precondition(!config.addMissingProviders([.openAI, .anthropic]))
        precondition(config.providers.count == 7)
        precondition(config.activeProviderId == "gemini" && config.activeModelId == "gemini-2.5-flash")

        // Without custom providers they go last.
        var plain = AIConfiguration(providers: [AIProviderConfig(id: "gemini", displayName: "Google Gemini", providerType: .gemini)])
        precondition(plain.addMissingProviders([.openAI, .anthropic]))
        precondition(plain.providers.map(\.id) == ["gemini", "openai", "anthropic"])

        // A config holding them saves and loads.
        let reloaded = try! JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(config))
        precondition(reloaded.providers.map(\.providerType) == config.providers.map(\.providerType))
        precondition(reloaded.providers.map(\.id) == config.providers.map(\.id))

        print("AIProviderConfigCheck passed")
    }
}
