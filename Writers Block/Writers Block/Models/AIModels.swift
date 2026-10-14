import Foundation

enum AIProvider: String, CaseIterable, Codable {
    case local = "LOCAL"
    case gemini = "GEMINI"
    case openai = "OPENAI"
    case claude = "CLAUDE"

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
    case gemini38Flash = "gemini-3.8-flash"
    case gemini4Argon = "gemini-4-argon"
    case gemini37Flash = "gemini-3.7-flash"
    case gemini36Flash = "gemini-3.6-flash"
    case gemini35Flash = "gemini-3.5-flash"
    case gemini35FlashLite = "gemini-3.5-flash-lite"
    case gemini31Pro = "gemini-3.1-pro-preview"
    case gemini3Flash = "gemini-3-flash-preview"
    case gemini31FlashLite = "gemini-3.1-flash-lite-preview"
    case gemini25Pro = "gemini-2.5-pro"
    case gemini25Flash = "gemini-2.5-flash"
    case gemini25FlashLite = "gemini-2.5-flash-lite"
    // OpenAI
    case gpt6Astra = "gpt-6-astra"
    case gpt61Sol = "gpt-6.1-sol"
    case gpt6Sol = "gpt-6-sol"
    case gpt6Luna = "gpt-6-luna"
    case gpt6Instant = "gpt-6-instant"
    case gpt55 = "gpt-5.5"
    case gpt55Pro = "gpt-5.5-pro"
    case gpt54 = "gpt-5.4"
    case gpt54Mini = "gpt-5.4-mini"
    case gpt54Nano = "gpt-5.4-nano"
    case gpt41 = "gpt-4.1"
    case gpt41Mini = "gpt-4.1-mini"
    case gpt41Nano = "gpt-4.1-nano"
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    // Claude
    case claudeFable51 = "claude-fable-5-1"
    case claudeFable5 = "claude-fable-5"
    case claudeOpus55 = "claude-opus-5-5"
    case claudeSonnet55 = "claude-sonnet-5-5"
    case claudeHaiku55 = "claude-haiku-5-5"
    case claudeOpus47 = "claude-opus-4-7"
    case claudeSonnet46 = "claude-sonnet-4-6"
    case claudeOpus4 = "claude-opus-4-20250514"
    case claudeSonnet4 = "claude-sonnet-4-20250514"
    case claudeHaiku45 = "claude-haiku-4-5-20251001"
    // Local on-device
    case localModel = "local-model"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini38Flash: return "Gemini 3.8 Flash"
        case .gemini4Argon: return "Gemini 4 Argon"
        case .gemini37Flash: return "Gemini 3.7 Flash"
        case .gemini36Flash: return "Gemini 3.6 Flash"
        case .gemini35Flash: return "Gemini 3.5 Flash"
        case .gemini35FlashLite: return "Gemini 3.5 Flash-Lite"
        case .gemini31Pro: return "Gemini 3.1 Pro"
        case .gemini3Flash: return "Gemini 3 Flash"
        case .gemini31FlashLite: return "Gemini 3.1 Flash Lite"
        case .gemini25Pro: return "Gemini 2.5 Pro"
        case .gemini25Flash: return "Gemini 2.5 Flash"
        case .gemini25FlashLite: return "Gemini 2.5 Flash Lite"
        case .gpt6Astra: return "GPT-6 Astra"
        case .gpt61Sol: return "GPT-6.1 Sol"
        case .gpt6Sol: return "GPT-6 Sol"
        case .gpt6Luna: return "GPT-6 Luna"
        case .gpt6Instant: return "GPT-6 Instant"
        case .gpt55: return "GPT-5.5"
        case .gpt55Pro: return "GPT-5.5 Pro"
        case .gpt54: return "GPT-5.4"
        case .gpt54Mini: return "GPT-5.4 Mini"
        case .gpt54Nano: return "GPT-5.4 Nano"
        case .gpt41: return "GPT-4.1"
        case .gpt41Mini: return "GPT-4.1 Mini"
        case .gpt41Nano: return "GPT-4.1 Nano"
        case .gpt4o: return "GPT-4o"
        case .gpt4oMini: return "GPT-4o Mini"
        case .claudeFable51: return "Claude Fable 5.1"
        case .claudeFable5: return "Claude Fable 5"
        case .claudeOpus55: return "Claude Opus 5.5"
        case .claudeSonnet55: return "Claude Sonnet 5.5"
        case .claudeHaiku55: return "Claude Haiku 5.5"
        case .claudeOpus4: return "Claude Opus 4"
        case .claudeSonnet4: return "Claude Sonnet 4"
        case .claudeOpus47: return "Claude Opus 4.7"
        case .claudeSonnet46: return "Claude Sonnet 4.6"
        case .claudeHaiku45: return "Claude Haiku 4.5"
        case .localModel: return "On-Device Model"
        }
    }

    var provider: AIProvider {
        switch self {
        case .gemini38Flash, .gemini4Argon, .gemini37Flash, .gemini36Flash,
             .gemini35Flash, .gemini35FlashLite, .gemini31Pro, .gemini3Flash,
             .gemini31FlashLite, .gemini25Pro, .gemini25Flash, .gemini25FlashLite:
            return .gemini
        case .gpt6Astra, .gpt61Sol, .gpt6Sol, .gpt6Luna, .gpt6Instant,
             .gpt55, .gpt55Pro, .gpt54, .gpt54Mini, .gpt54Nano,
             .gpt41, .gpt41Mini, .gpt41Nano, .gpt4o, .gpt4oMini:
            return .openai
        case .claudeFable51, .claudeFable5, .claudeOpus55, .claudeSonnet55, .claudeHaiku55,
             .claudeOpus47, .claudeSonnet46, .claudeOpus4, .claudeSonnet4, .claudeHaiku45:
            return .claude
        case .localModel:
            return .local
        }
    }

    static let `default`: AIModel = .gemini38Flash

    static func models(for provider: AIProvider) -> [AIModel] {
        AIModel.allCases.filter { $0.provider == provider }
    }
}

