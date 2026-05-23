//
//  Writers_BlockTests.swift
//  Writers BlockTests
//
//  Created by Tyler Manring on 4/6/26.
//

import Testing
@testable import Writers_Block

struct Writers_BlockTests {

    @Test func rhymeContextIgnoresSectionHeadersForSchemePosition() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .aabb
        viewModel.lyrics = "[Verse 1]\nfirst light\nsecond night"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()

        #expect(context.currentLetter == "A")
        #expect(context.targetLine == "first light")
        #expect(context.currentLineIndex == 2)
        #expect(context.currentSection == .verse)
    }

    @Test func rhymeContextUsesLatestPreviousLyricWithSameLetter() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .abab
        viewModel.lyrics = "[Chorus]\nfirst glow\nsecond rain\nthird road\nfourth rain"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()

        #expect(context.currentLetter == "B")
        #expect(context.targetLine == "second rain")
        #expect(context.currentSection == .chorus)
    }

    @Test func rhymeContextDetectsBridgeSectionForPromptShaping() {
        let viewModel = EditorViewModel()
        viewModel.lyrics = "[Verse 1]\nfirst line\n\n[Bridge]\nnew angle"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()

        #expect(context.currentSection == .bridge)
    }

    @Test func openAIModelPickerStartsWithCurrentGPT5Models() {
        let modelIDs = AIModel.models(for: .openai).map(\.id)

        #expect(Array(modelIDs.prefix(5)) == [
            "gpt-5.5",
            "gpt-5.5-pro",
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.4-nano"
        ])
        #expect(modelIDs.contains("gpt-4o"))
        #expect(modelIDs.contains("gpt-4o-mini"))
    }

    @Test func claudeModelPickerUsesCurrentClaudeModels() {
        let modelIDs = AIModel.models(for: .claude).map(\.id)

        #expect(Array(modelIDs.prefix(2)) == [
            "claude-opus-4-7",
            "claude-sonnet-4-6"
        ])
        #expect(modelIDs.contains("claude-opus-4-20250514"))
        #expect(modelIDs.contains("claude-sonnet-4-20250514"))
        #expect(modelIDs.contains("claude-haiku-4-5-20251001"))
    }

    @Test func prosodyAnalyzerCountsDictionaryStress() {
        let dictionary = Self.fixtureDictionary
        let prosody = ProsodyAnalyzer.analyzeLine("yellow music", dictionary: dictionary)

        #expect(prosody.syllableCount == 4)
        #expect(prosody.stressPattern == [1, 0, 1, 0])
        #expect(prosody.feet == "ˈDA da | ˈDA da")
    }

    @Test func prosodyAnalyzerRendersIpaPreview() {
        let prosody = ProsodyAnalyzer.analyzeWord("music", dictionary: Self.fixtureDictionary)

        #expect(prosody.ipa == "ˈmjuzɪk")
        #expect(prosody.isFallback == false)
    }

    @Test func prosodyAnalyzerUsesFallbackForUnknownWords() {
        let prosody = ProsodyAnalyzer.analyzeWord("Scottys", dictionary: Self.fixtureDictionary)

        #expect(prosody.syllableCount == 2)
        #expect(prosody.stressPattern == [1, 0])
        #expect(prosody.isFallback)
    }

    @Test func prosodyAnalyzerUsesCmuPhonesForRhymeKeys() {
        let roadKeys = ProsodyAnalyzer.rhymeKeys(for: "road", dictionary: Self.fixtureDictionary)
        let glowedKeys = ProsodyAnalyzer.rhymeKeys(for: "glowed", dictionary: Self.fixtureDictionary)

        #expect(!Set(roadKeys).intersection(glowedKeys).isEmpty)
    }

    private static let fixtureDictionary = PronunciationDictionary.fromLines([
        "yellow\tY EH1 L OW0",
        "music\tM Y UW1 Z IH0 K",
        "road\tR OW1 D",
        "glowed\tG L OW1 D",
        "orange\tAO1 R AH0 N JH|AO1 R IH0 N JH"
    ])

}
