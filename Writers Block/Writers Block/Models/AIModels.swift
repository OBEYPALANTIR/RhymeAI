import Foundation

enum AIProvider: String, CaseIterable, Codable {
    case gemini = "GEMINI"
    case openai = "OPENAI"
    case claude = "CLAUDE"
    case local = "LOCAL"

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .local: return "Local"
        }
    }

    var keyHint: String {
        switch self {
        case .gemini: return "Get your key at aistudio.google.com"
        case .openai: return "Get your key at platform.openai.com"
        case .claude: return "Get your key at console.anthropic.com"
        case .local: return "Runs on-device with Apple Foundation Models when available."
        }
    }
}

enum AIModel: String, CaseIterable, Codable, Identifiable {
    // Gemini
    case gemini31Pro = "gemini-3.1-pro-preview"
    case gemini3Flash = "gemini-3-flash-preview"
    case gemini31FlashLite = "gemini-3.1-flash-lite-preview"
    case gemini25Pro = "gemini-2.5-pro"
    case gemini25Flash = "gemini-2.5-flash"
    case gemini25FlashLite = "gemini-2.5-flash-lite"
    // OpenAI
    case gpt41 = "gpt-4.1"
    case gpt41Mini = "gpt-4.1-mini"
    case gpt41Nano = "gpt-4.1-nano"
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    // Claude
    case claudeSonnet = "claude-sonnet-4-20250514"
    case claudeHaiku = "claude-haiku-4-5-20251001"
    case claudeOpus = "claude-opus-4-20250514"
    // Local on-device
    case localModel = "local-model"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini31Pro: return "Gemini 3.1 Pro"
        case .gemini3Flash: return "Gemini 3 Flash"
        case .gemini31FlashLite: return "Gemini 3.1 Flash Lite"
        case .gemini25Pro: return "Gemini 2.5 Pro"
        case .gemini25Flash: return "Gemini 2.5 Flash"
        case .gemini25FlashLite: return "Gemini 2.5 Flash Lite"
        case .gpt41: return "GPT-4.1"
        case .gpt41Mini: return "GPT-4.1 Mini"
        case .gpt41Nano: return "GPT-4.1 Nano"
        case .gpt4o: return "GPT-4o"
        case .gpt4oMini: return "GPT-4o Mini"
        case .claudeSonnet: return "Claude Sonnet 4"
        case .claudeHaiku: return "Claude Haiku 4.5"
        case .claudeOpus: return "Claude Opus 4"
        case .localModel: return "On-Device Model"
        }
    }

    var provider: AIProvider {
        switch self {
        case .gemini31Pro, .gemini3Flash, .gemini31FlashLite,
             .gemini25Pro, .gemini25Flash, .gemini25FlashLite:
            return .gemini
        case .gpt41, .gpt41Mini, .gpt41Nano, .gpt4o, .gpt4oMini:
            return .openai
        case .claudeSonnet, .claudeHaiku, .claudeOpus:
            return .claude
        case .localModel:
            return .local
        }
    }

    static let `default`: AIModel = .gemini3Flash

    static func models(for provider: AIProvider) -> [AIModel] {
        AIModel.allCases.filter { $0.provider == provider }
    }
}
