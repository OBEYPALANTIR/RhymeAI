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
    }

    @Test func rhymeContextUsesLatestPreviousLyricWithSameLetter() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .abab
        viewModel.lyrics = "[Chorus]\nfirst glow\nsecond rain\nthird road\nfourth rain"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()

        #expect(context.currentLetter == "B")
        #expect(context.targetLine == "second rain")
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
    }

    @Test func claudeModelPickerUsesCurrentClaudeModels() {
        let modelIDs = AIModel.models(for: .claude).map(\.id)

        #expect(modelIDs == [
            "claude-opus-4-7",
            "claude-sonnet-4-6",
            "claude-haiku-4-5-20251001"
        ])
    }

}
