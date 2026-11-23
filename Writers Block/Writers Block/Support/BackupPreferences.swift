import CoreFoundation
import Foundation

/// The v1 preferences companion. Transport and core restore own its lifecycle.
@MainActor

struct BackupPreferences {
    enum RecordError: Error {
        case tooLarge
    }

    private struct Payload: Codable {
        struct ModelChoice: Codable {
            let provider: String
            let model: String

            var isPortable: Bool {
                guard let provider = AIProvider(rawValue: provider),
                      let model = AIModel(rawValue: model) else { return false }
                // The local choice is backed by this installation's inventory and runtime.
                return provider != .local && model.provider == provider
            }
        }

        var appearance: String?
        var handedness: String?
        var highlight: Bool?
        var syllableColoring: Bool?
        var stressPreview: Bool?
        var rhymeHighlight: Bool?
        var beatGrid: Bool?
        var modelChoice: ModelChoice?
    }

    private static let maximumRecordBytes = 4 * 1024
    private let payload: Payload

    /// Pass the writable application or suite domain of the supplied defaults.
    static func capture(from defaults: UserDefaults, domain: String) -> Self {
        let saved = defaults.persistentDomain(forName: domain) ?? [:]

        func toggle(_ key: String) -> Bool? {
            guard let number = saved[key] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }

        var payload = Payload(
            appearance: saved[AppAppearanceStyle.storageKey] as? String,
            handedness: saved[DominantHand.storageKey] as? String,
            highlight: toggle("editor.isHighlightEnabled"),
            syllableColoring: toggle("editor.isSyllableColoringEnabled"),
            stressPreview: toggle("editor.isStressPreviewEnabled"),
            rhymeHighlight: toggle("editor.isRhymeHighlightEnabled"),
            beatGrid: toggle("editor.isBeatGridEnabled")
        )
        if let provider = saved["selectedProvider"] as? String,
           let model = saved["selectedModel"] as? String {
            payload.modelChoice = Payload.ModelChoice(provider: provider, model: model)
        }
        return Self(validating: payload)
    }

    /// Fill unset choices synchronously on the same actor as the editor.
    func apply(to defaults: UserDefaults, domain: String) {
        let saved = defaults.persistentDomain(forName: domain) ?? [:]

        func fill<Value>(_ value: Value?, forKey key: String) {
            guard saved[key] == nil, let value else { return }
            defaults.set(value, forKey: key)
        }

        fill(payload.appearance, forKey: AppAppearanceStyle.storageKey)
        fill(payload.handedness, forKey: DominantHand.storageKey)
        fill(payload.highlight, forKey: "editor.isHighlightEnabled")
        fill(payload.syllableColoring, forKey: "editor.isSyllableColoringEnabled")
        fill(payload.stressPreview, forKey: "editor.isStressPreviewEnabled")
        fill(payload.rhymeHighlight, forKey: "editor.isRhymeHighlightEnabled")
        fill(payload.beatGrid, forKey: "editor.isBeatGridEnabled")
        if let choice = payload.modelChoice, saved["selectedProvider"] == nil, saved["selectedModel"] == nil {
            defaults.set(choice.provider, forKey: "selectedProvider")
            defaults.set(choice.model, forKey: "selectedModel")
        }
    }

    private init(validating payload: Payload) {
        var validated = payload
        validated.appearance = payload.appearance.flatMap(AppAppearanceStyle.init(rawValue:))?.rawValue
        validated.handedness = payload.handedness.flatMap(DominantHand.init(rawValue:))?.rawValue
        validated.modelChoice = payload.modelChoice?.isPortable == true ? payload.modelChoice : nil
        self.payload = validated
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumRecordBytes else { throw RecordError.tooLarge }
        return Self(validating: try JSONDecoder().decode(Payload.self, from: data))
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(payload)
        guard data.count <= Self.maximumRecordBytes else { throw RecordError.tooLarge }
        return data
    }
}
