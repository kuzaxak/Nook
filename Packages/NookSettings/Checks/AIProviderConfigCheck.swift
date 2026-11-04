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

        pageTranslation(saved: config)
        print("AIProviderConfigCheck passed")
    }

    static func pageTranslation(saved: AIConfiguration) {
        // A config saved before page translation had a setting keeps decoding, with none chosen.
        precondition(saved.translationEngine == nil && saved.translationProviderId == nil && saved.translationModelId == nil)

        var config = AIConfiguration(
            providers: [
                AIProviderConfig(id: "apple_intelligence", displayName: "Apple Intelligence", providerType: .appleIntelligence),
                AIProviderConfig(id: "openai", displayName: "OpenAI", providerType: .openAI),
                AIProviderConfig(id: "anthropic", displayName: "Anthropic", providerType: .anthropic),
                AIProviderConfig(id: "ollama", displayName: "Ollama (Local)", providerType: .ollama),
                AIProviderConfig(id: "lmstudio", displayName: "LM Studio", providerType: .openAICompatible, isEnabled: false)
            ],
            models: [
                AIModelConfig(id: "on-device", displayName: "On-Device", providerId: "apple_intelligence"),
                AIModelConfig(id: "gpt-6-luna", displayName: "GPT-6 Luna", providerId: "openai"),
                AIModelConfig(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", providerId: "anthropic"),
                AIModelConfig(id: "gemma", displayName: "Gemma", providerId: "ollama")
            ]
        )
        let hasKey: (AIProviderConfig) -> Bool = { $0.id == "openai" }
        precondition(config.translationProviders(hasKey: hasKey).map(\.id) == ["openai", "ollama"],
                     "Apple Intelligence, a provider without its key and a switched-off one cannot translate")

        var listed = config
        listed.models.insert(AIModelConfig(id: "text-embedding-3-small", displayName: "text-embedding-3-small", providerId: "openai"), at: 0)
        listed.models.append(AIModelConfig(id: "whisper-1", displayName: "whisper-1", providerId: "openai"))
        precondition(listed.translationModels(for: "openai").map(\.id) == ["gpt-6-luna"], "an OpenAI model that cannot chat is not offered")
        precondition(listed.translationModels(for: "ollama").map(\.id) == ["gemma"])
        precondition(listed.translationModels(for: "gone").isEmpty)

        config.translationEngine = .ai
        config.translationProviderId = "openai"
        config.translationModelId = "gpt-6-luna"
        precondition(config.translationTarget(hasKey: hasKey).map { [$0.provider.id, $0.model.id] } == ["openai", "gpt-6-luna"])

        config.translationModelId = "gemma"
        precondition(config.translationTarget(hasKey: hasKey) == nil, "the model must be the chosen provider's")
        config.translationModelId = "gpt-gone"
        precondition(config.translationTarget(hasKey: hasKey) == nil, "a removed model is no target")
        config.translationProviderId = "anthropic"
        config.translationModelId = "claude-haiku-4-5"
        precondition(config.translationTarget(hasKey: hasKey) == nil, "nor is a provider whose key was cleared")

        config.translationProviderId = "openai"
        config.translationModelId = "gpt-6-luna"

        // A model added in the Translation section goes to the translation provider, not the chat's.
        var adding = config
        adding.activeProviderId = "anthropic"
        adding.activeModelId = "claude-haiku-4-5"
        let terra = AIModelConfig(id: "gpt-6-terra", displayName: "GPT-6 Terra", providerId: "openai")
        adding.addTranslationModel(terra)
        adding.addTranslationModel(terra)
        precondition(adding.translationModelId == "gpt-6-terra", "and is the one pages translate with")
        precondition(adding.models.filter { $0.id == "gpt-6-terra" }.count == 1)
        precondition(adding.activeProviderId == "anthropic" && adding.activeModelId == "claude-haiku-4-5", "the chat keeps its provider and model")
        adding.addTranslationModel(AIModelConfig(id: "text-embedding-3-small", displayName: "text-embedding-3-small", providerId: "openai"))
        precondition(adding.translationModelId == "gpt-6-terra", "a model that cannot chat is not picked")
        adding.addTranslationModel(AIModelConfig(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", providerId: "anthropic"))
        precondition(!adding.models.contains { $0.id == "claude-sonnet-5-5" } && adding.translationModelId == "gpt-6-terra",
                     "nor is another provider's")

        let reloaded = try! JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(config))
        precondition(reloaded.translationEngine == .ai)
        precondition(reloaded.translationTarget(hasKey: hasKey).map { [$0.provider.id, $0.model.id] } == ["openai", "gpt-6-luna"])
        precondition(PageTranslationEngine.allCases == [.onDevice, .ai])
        precondition(PageTranslationEngine.onDevice.displayName == "Apple (on device)" && PageTranslationEngine.ai.displayName == "AI model")
    }
}
