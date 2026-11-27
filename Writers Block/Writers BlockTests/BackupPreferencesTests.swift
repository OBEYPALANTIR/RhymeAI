import Foundation
import Testing
@testable import Writers_Block

@MainActor
struct BackupPreferencesTests {
    @Test func restoresExplicitPreferencesAndCatalogModelIntoUnsetDefaults() throws {
        let source = try TestDefaults()
        let destination = try TestDefaults()
        defer { source.clear(); destination.clear() }

        let expected: [String: Any] = [
            AppAppearanceStyle.storageKey: AppAppearanceStyle.graphite.rawValue,
            DominantHand.storageKey: DominantHand.left.rawValue,
            "editor.isHighlightEnabled": false,
            "editor.isSyllableColoringEnabled": true,
            "editor.isStressPreviewEnabled": true,
            "editor.isRhymeHighlightEnabled": false,
            "editor.isBeatGridEnabled": true,
            "selectedProvider": AIProvider.openai.rawValue,
            "selectedModel": AIModel.gpt4oMini.rawValue
        ]
        source.defaults.setPersistentDomain(expected, forName: source.name)
        destination.defaults.register(defaults: [AppAppearanceStyle.storageKey: AppAppearanceStyle.ink.rawValue])

        let data = try BackupPreferences.capture(from: source.defaults, domain: source.name).encoded()
        try BackupPreferences.decode(data).apply(to: destination.defaults, domain: destination.name)

        let reopened = try #require(UserDefaults(suiteName: destination.name))
        let saved = reopened.persistentDomain(forName: destination.name) ?? [:]
        #expect(NSDictionary(dictionary: saved).isEqual(to: expected))
    }

    @Test func keepsExplicitDestinationChoicesAndTreatsTheModelPairAsOneChoice() throws {
        let destination = try TestDefaults()
        defer { destination.clear() }
        destination.defaults.set(AppAppearanceStyle.ink.rawValue, forKey: AppAppearanceStyle.storageKey)
        destination.defaults.set(false, forKey: "editor.isHighlightEnabled")
        destination.defaults.set(AIProvider.gemini.rawValue, forKey: "selectedProvider")
        let data = Data("""
        {"appearance":"graphite","highlight":true,"beatGrid":true,
         "modelChoice":{"provider":"OPENAI","model":"gpt-4o-mini"}}
        """.utf8)

        try BackupPreferences.decode(data).apply(to: destination.defaults, domain: destination.name)
        let saved = destination.defaults.persistentDomain(forName: destination.name) ?? [:]

        #expect(saved[AppAppearanceStyle.storageKey] as? String == AppAppearanceStyle.ink.rawValue)
        #expect(saved["editor.isHighlightEnabled"] as? Bool == false)
        #expect(saved["editor.isBeatGridEnabled"] as? Bool == true)
        #expect(saved["selectedProvider"] as? String == AIProvider.gemini.rawValue)
        #expect(saved["selectedModel"] == nil)
    }

    @Test func omitsPrivateDefaultsAndIgnoresInjectedFields() throws {
        let source = try TestDefaults()
        let destination = try TestDefaults()
        defer { source.clear(); destination.clear() }
        source.defaults.setPersistentDomain([
            AppAppearanceStyle.storageKey: AppAppearanceStyle.paper.rawValue,
            "apiKey_fixture": "synthetic-credential",
            "drive-sync-client-id": "synthetic-identity",
            "editor.useWholeSongContext": true,
            "privacy.cloudAISharingConsent.v2.fixture": true,
            "customGGUFModels": ["synthetic-inventory"],
            "selectedGGUFModelFileName": "synthetic-file"
        ], forName: source.name)

        let data = try BackupPreferences.capture(from: source.defaults, domain: source.name).encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["appearance"])

        let injected = Data("""
        {"appearance":"paper","apiKey_fixture":"synthetic-credential","drive-sync-client-id":"synthetic-identity",
         "editor.useWholeSongContext":true,"privacy.cloudAISharingConsent.v2.fixture":true,
         "customGGUFModels":["synthetic-inventory"],"selectedGGUFModelFileName":"synthetic-file"}
        """.utf8)
        let record = try BackupPreferences.decode(injected)
        record.apply(to: destination.defaults, domain: destination.name)
        let saved = destination.defaults.persistentDomain(forName: destination.name) ?? [:]
        #expect(Set(saved.keys) == [AppAppearanceStyle.storageKey])
        let reencoded = try #require(JSONSerialization.jsonObject(with: record.encoded()) as? [String: Any])
        #expect(Set(reencoded.keys) == ["appearance"])
    }

    @Test func emptyUnknownAndUnsupportedChoicesLeaveDefaultsAlone() throws {
        let destination = try TestDefaults()
        defer { destination.clear() }
        let fixtures = [
            "{}",
            #"{"appearance":"future","handedness":"future","modelChoice":{"provider":"FUTURE","model":"future"}}"#,
            #"{"modelChoice":{"provider":"OPENAI","model":"gemini-3.5-flash"}}"#,
            #"{"modelChoice":{"provider":"LOCAL","model":"local-model"}}"#
        ]

        for fixture in fixtures {
            let record = try BackupPreferences.decode(Data(fixture.utf8))
            record.apply(to: destination.defaults, domain: destination.name)
            #expect(destination.defaults.persistentDomain(forName: destination.name)?.isEmpty ?? true)
        }
    }

    @Test func rejectsOversizedAndMalformedRecordsBeforeApplyingDefaults() {
        #expect(throws: BackupPreferences.RecordError.self) {
            try BackupPreferences.decode(Data(repeating: 0x20, count: 4_097))
        }
        #expect(throws: DecodingError.self) {
            try BackupPreferences.decode(Data(#"{"beatGrid":"yes"}"#.utf8))
        }
    }

    private struct TestDefaults {
        let name = "BackupPreferencesTests.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
        }

        func clear() {
            defaults.removePersistentDomain(forName: name)
        }
    }
}
