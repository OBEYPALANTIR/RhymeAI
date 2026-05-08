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

}
