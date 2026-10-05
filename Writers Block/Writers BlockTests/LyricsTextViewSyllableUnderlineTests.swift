import SwiftUI
import Testing
import UIKit
@testable import Writers_Block

/// With rhyme colouring and the syllable cue both on, each word is underlined
/// in its syllable colour. The underline is drawn from the editor's text
/// storage. These tests pin which ranges carry it and that putting it there
/// is not an edit.
@MainActor
struct LyricsTextViewSyllableUnderlineTests {
    private static let lyric = "[Verse]\nyellow music\nfollow music\nmellow harmony"
    private static let ink = UIColor.black

    private func makeTextView(_ text: String = lyric) -> UITextView {
        let textView = LyricsUITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        textView.text = text
        return textView
    }

    private func spans(rhyme: Bool, syllables: Bool) async -> [LyricsColorSpan] {
        await LyricsHighlighting.spans(
            text: Self.lyric, rhymeEnabled: rhyme, syllablesEnabled: syllables, isDark: false
        )
    }

    /// The attribute over the whole word, or nil when any part of it lacks it.
    private func attribute<T>(_ key: NSAttributedString.Key, in textView: UITextView, at word: String) -> T? {
        let found = (textView.text as NSString).range(of: word)
        var effective = NSRange()
        let value = textView.textStorage.attribute(key, at: found.location, effectiveRange: &effective)
        guard NSMaxRange(effective) >= NSMaxRange(found) else { return nil }
        return value as? T
    }

    private func underlinedCharacterCount(in textView: UITextView) -> Int {
        var count = 0
        let full = NSRange(location: 0, length: textView.textStorage.length)
        textView.textStorage.enumerateAttributes(in: full) { attributes, range, _ in
            if LyricsTextView.Coordinator.underlineAttributeKeys.contains(where: { attributes[$0] != nil }) {
                count += range.length
            }
        }
        return count
    }

    @Test func wordsAreUnderlinedInTheirSyllableColourWhenBothGuidesAreOn() async throws {
        let textView = makeTextView()

        LyricsTextView.Coordinator.applyColors(
            await spans(rhyme: true, syllables: true), to: textView, foreground: Self.ink
        )

        #expect(attribute(.underlineStyle, in: textView, at: "yellow") == NSUnderlineStyle.single.rawValue)
        let twoSyllables: UIColor = try #require(attribute(.underlineColor, in: textView, at: "yellow"))
        let threeSyllables: UIColor = try #require(attribute(.underlineColor, in: textView, at: "harmony"))
        // The colour encodes the syllable count, whether or not the word rhymes.
        #expect(attribute(.underlineColor, in: textView, at: "follow") == twoSyllables)
        #expect(attribute(.underlineColor, in: textView, at: "mellow") == twoSyllables)
        #expect(twoSyllables != threeSyllables)
        #expect(twoSyllables != Self.ink)
        // The section label is not analysed.
        #expect(attribute(.underlineStyle, in: textView, at: "[Verse]") as Int? == nil)
        #expect(textView.text == Self.lyric)
    }

    @Test func aNewInstallsDefaultTogglesPutNothingOnTheStorage() async {
        // Syllable cue on, rhyme colouring off: the word colour carries the cue.
        let textView = makeTextView()

        LyricsTextView.Coordinator.applyColors(
            await spans(rhyme: false, syllables: true), to: textView, foreground: Self.ink
        )

        #expect(underlinedCharacterCount(in: textView) == 0)
    }

    @Test func underlinesAreRemovedWhenAGuideIsTurnedOff() async {
        let textView = makeTextView()
        LyricsTextView.Coordinator.applyColors(
            await spans(rhyme: true, syllables: true), to: textView, foreground: Self.ink
        )
        #expect(underlinedCharacterCount(in: textView) > 0)

        LyricsTextView.Coordinator.applyColors(
            await spans(rhyme: true, syllables: false), to: textView, foreground: Self.ink
        )
        #expect(underlinedCharacterCount(in: textView) == 0)

        LyricsTextView.Coordinator.applyColors(
            await spans(rhyme: true, syllables: true), to: textView, foreground: Self.ink
        )
        LyricsTextView.Coordinator.applyColors([], to: textView, foreground: Self.ink)
        #expect(underlinedCharacterCount(in: textView) == 0)
        #expect(textView.text == Self.lyric)
    }

    @Test func applyingUnderlinesIsNotAnEditAndKeepsSelectionAndUndo() async throws {
        // Given an editor the user has typed into
        var boundText = ""
        var textWrites = 0
        var cursorChanges = 0
        let parent = LyricsTextView(
            text: Binding(get: { boundText }, set: { boundText = $0; textWrites += 1 }),
            onCursorChange: { _ in cursorChanges += 1 }
        )
        let coordinator = parent.makeCoordinator()
        let textView = makeTextView("")
        textView.delegate = coordinator
        coordinator.attach(to: textView)
        let viewController = UIViewController()
        viewController.view.addSubview(textView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        #expect(textView.becomeFirstResponder())
        textView.insertText(Self.lyric)
        #expect(boundText == Self.lyric)
        let undoManager = try #require(textView.undoManager)
        let couldUndo = undoManager.canUndo
        let selection = (Self.lyric as NSString).range(of: "follow")
        textView.selectedRange = selection
        textWrites = 0
        cursorChanges = 0

        // When the underlines are applied, removed, and applied again
        let underlined = await spans(rhyme: true, syllables: true)
        coordinator.isApplyingProgrammaticUpdate = true
        coordinator.installColors(underlined, for: Self.lyric, on: textView, foreground: Self.ink)
        #expect(underlinedCharacterCount(in: textView) > 0)
        coordinator.installColors([], for: Self.lyric, on: textView, foreground: Self.ink)
        coordinator.installColors(underlined, for: Self.lyric, on: textView, foreground: Self.ink)
        coordinator.isApplyingProgrammaticUpdate = false

        // Then nothing was published, moved or added to the undo stack
        #expect(textWrites == 0)
        #expect(cursorChanges == 0)
        #expect(boundText == Self.lyric)
        #expect(textView.text == Self.lyric)
        #expect(textView.selectedRange == selection)
        #expect(undoManager.canUndo == couldUndo)
        #expect(!undoManager.canRedo)
    }

    @Test func textTypedAfterAnUnderlinedWordDoesNotInheritTheUnderline() async {
        let parent = LyricsTextView(text: .constant(Self.lyric), onCursorChange: { _ in })
        let coordinator = parent.makeCoordinator()
        let textView = makeTextView()
        textView.delegate = coordinator
        LyricsTextView.Coordinator.applyColors(
            await spans(rhyme: true, syllables: true), to: textView, foreground: Self.ink
        )
        let end = textView.textStorage.length
        textView.selectedRange = NSRange(location: end, length: 0)
        textView.typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        textView.typingAttributes[.underlineColor] = UIColor.red

        _ = coordinator.textView(textView, shouldChangeTextIn: NSRange(location: end, length: 0), replacementText: "s")

        for key in LyricsTextView.Coordinator.underlineAttributeKeys {
            #expect(textView.typingAttributes[key] == nil)
        }
    }

    @Test func underlinesAreLeftAloneWhileTextIsBeingComposed() async throws {
        let textView = makeTextView()
        let viewController = UIViewController()
        viewController.view.addSubview(textView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        #expect(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        try #require(textView.markedTextRange != nil)

        LyricsTextView.Coordinator.applyUnderlines(await spans(rhyme: true, syllables: true), to: textView)

        #expect(attribute(.underlineStyle, in: textView, at: "yellow") as Int? == nil)
    }

    @Test func copiedLyricsArePlainText() async throws {
        let textView = makeTextView()
        LyricsTextView.Coordinator.applyColors(
            await spans(rhyme: true, syllables: true), to: textView, foreground: Self.ink
        )
        textView.selectedRange = (Self.lyric as NSString).range(of: "yellow music")

        textView.copy(nil)

        #expect(UIPasteboard.general.string == "yellow music")
        let richTypes = UIPasteboard.general.types.filter {
            $0.localizedCaseInsensitiveContains("rtf") || $0.localizedCaseInsensitiveContains("archive")
                || $0.localizedCaseInsensitiveContains("html")
        }
        #expect(richTypes.isEmpty)
    }
}
