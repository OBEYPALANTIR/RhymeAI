import SwiftUI
import Testing
import UIKit
@testable import Writers_Block

/// With rhyme colouring and the syllable cue both on, each word is underlined
/// in its syllable colour. The underline is drawn by a layer behind the text,
/// never on the text storage. These tests pin which ranges carry it, that an
/// edit moves it with the text before the next analysis, how it moves, and
/// that drawing it is not an edit.
@MainActor
struct LyricsTextViewSyllableUnderlineTests {
    private static let lyric = "[Verse]\nyellow music\nfollow music\nmellow harmony"
    private static let ink = UIColor.black

    @MainActor
    private final class Editor {
        let coordinator: LyricsTextView.Coordinator
        let textView: LyricsUITextView
        let window: UIWindow

        init(_ text: String, debounce: Duration = .seconds(60)) {
            textView = LyricsUITextView(usingTextLayoutManager: true)
            textView.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
            var parent = LyricsTextView(text: .constant(text), onCursorChange: { _ in })
            parent.rhymeHighlightEnabled = true
            parent.syllableColoringEnabled = true
            coordinator = LyricsTextView.Coordinator(parent, colorAnalysisDebounce: debounce)
            textView.delegate = coordinator
            textView.font = LyricsTextView.lyricsFont(for: .large)
            coordinator.attach(to: textView)
            let viewController = UIViewController()
            viewController.view.addSubview(textView)
            window.rootViewController = viewController
            window.makeKeyAndVisible()
            textView.text = text
            textView.layoutIfNeeded()
        }

        var underlines: SyllableUnderlineView { coordinator.underlineView! }

        func analyse() async {
            let text: String = textView.text
            let spans = await LyricsHighlighting.spans(text: text, rhymeEnabled: true, syllablesEnabled: true, isDark: false)
            coordinator.installColors(spans, for: text, on: textView, foreground: LyricsTextViewSyllableUnderlineTests.ink)
        }

        /// The keyboard asks the delegate before each edit; a programmatic
        /// `deleteBackward` does not, so ask on its behalf.
        func deleteBackward() {
            let caret = textView.selectedRange.location
            _ = coordinator.textView(textView, shouldChangeTextIn: NSRange(location: caret - 1, length: 1), replacementText: "")
            textView.deleteBackward()
        }

        func type(_ text: String) {
            _ = coordinator.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: text)
            textView.insertText(text)
        }

        func segment(_ word: String) -> SyllableUnderlineView.Segment? {
            let location = (textView.text as NSString).range(of: word).location
            return underlines.segments.first { $0.location == location }
        }

        func wordRect(at location: Int, length: Int) -> CGRect? {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: location),
                  let end = textView.position(from: start, offset: length),
                  let range = textView.textRange(from: start, to: end) else { return nil }
            return textView.firstRect(for: range)
        }
    }

    private func spans(rhyme: Bool, syllables: Bool) async -> [LyricsColorSpan] {
        await LyricsHighlighting.spans(
            text: Self.lyric, rhymeEnabled: rhyme, syllablesEnabled: syllables, isDark: false
        )
    }

    private func storageHasUnderline(_ textView: UITextView) -> Bool {
        var found = false
        let full = NSRange(location: 0, length: textView.textStorage.length)
        textView.textStorage.enumerateAttributes(in: full) { attributes, _, _ in
            if attributes[.underlineStyle] != nil || attributes[.underlineColor] != nil { found = true }
        }
        return found
    }

    @Test func wordsAreUnderlinedInTheirSyllableColourWhenBothGuidesAreOn() async throws {
        let editor = Editor(Self.lyric)
        editor.underlines.motionEnabled = { false }

        await editor.analyse()

        let yellow = try #require(editor.segment("yellow"))
        let harmony = try #require(editor.segment("harmony"))
        // The colour encodes the syllable count, whether or not the word rhymes.
        #expect(editor.segment("follow")?.color == yellow.color)
        #expect(editor.segment("mellow")?.color == yellow.color)
        #expect(yellow.color != harmony.color)
        #expect(yellow.color != Self.ink)
        // The line sits under the word, as wide as the word.
        let word = try #require(editor.wordRect(at: yellow.location, length: 6))
        #expect(abs(yellow.frame.minX - word.minX) < 1)
        #expect(abs(yellow.frame.width - word.width) < 1)
        #expect(yellow.frame.minY > word.midY && yellow.frame.maxY <= word.maxY + 2)
        #expect(editor.underlines.line(at: yellow.location)?.frame == yellow.frame)
        // The section label is not analysed.
        #expect(editor.segment("[Verse]") == nil)
        #expect(!storageHasUnderline(editor.textView))
        #expect(editor.textView.text == Self.lyric)
    }

    @Test func aNewInstallsDefaultTogglesDrawNoUnderline() async throws {
        // Syllable cue on, rhyme colouring off: the word colour carries the cue.
        let editor = Editor(Self.lyric)

        editor.coordinator.installColors(
            await spans(rhyme: false, syllables: true), for: Self.lyric, on: editor.textView, foreground: Self.ink
        )

        #expect(editor.underlines.segments.isEmpty)
        #expect(editor.underlines.layer.sublayers?.isEmpty ?? true)
    }

    @Test func underlinesAreRemovedWhenAGuideIsTurnedOff() async {
        let editor = Editor(Self.lyric)
        editor.underlines.motionEnabled = { false }
        await editor.analyse()
        #expect(!editor.underlines.segments.isEmpty)

        editor.coordinator.installColors(
            await spans(rhyme: true, syllables: false), for: Self.lyric, on: editor.textView, foreground: Self.ink
        )
        #expect(editor.underlines.segments.isEmpty)
        #expect(editor.underlines.layer.sublayers?.isEmpty ?? true)

        await editor.analyse()
        editor.coordinator.installColors([], for: Self.lyric, on: editor.textView, foreground: Self.ink)
        #expect(editor.underlines.layer.sublayers?.isEmpty ?? true)
        #expect(editor.textView.text == Self.lyric)
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
        let textView = LyricsUITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
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
        #expect(coordinator.underlineView?.segments.isEmpty == false)
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

    @Test func typingNextToAnUnderlinedWordPutsNoUnderlineOnTheStorage() async {
        let editor = Editor(Self.lyric)
        await editor.analyse()
        #expect(editor.textView.becomeFirstResponder())
        editor.textView.selectedRange = NSRange(location: editor.textView.textStorage.length, length: 0)

        editor.type("s")

        #expect(editor.textView.text == Self.lyric + "s")
        #expect(!storageHasUnderline(editor.textView))
    }

    @Test func drawingUnderlinesLeavesACompositionAlone() async throws {
        let editor = Editor(Self.lyric)
        #expect(editor.textView.becomeFirstResponder())
        editor.textView.selectedRange = NSRange(location: editor.textView.textStorage.length, length: 0)
        editor.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        try #require(editor.textView.markedTextRange != nil)

        editor.coordinator.installColors(
            await spans(rhyme: true, syllables: true), for: Self.lyric, on: editor.textView, foreground: Self.ink
        )

        #expect(editor.textView.markedTextRange != nil)
        #expect(!storageHasUnderline(editor.textView))
    }

    @Test func copiedLyricsArePlainText() async throws {
        let editor = Editor(Self.lyric)
        await editor.analyse()
        editor.textView.selectedRange = (Self.lyric as NSString).range(of: "yellow music")

        editor.textView.copy(nil)

        #expect(UIPasteboard.general.string == "yellow music")
        let richTypes = UIPasteboard.general.types.filter {
            $0.localizedCaseInsensitiveContains("rtf") || $0.localizedCaseInsensitiveContains("archive")
                || $0.localizedCaseInsensitiveContains("html")
        }
        #expect(richTypes.isEmpty)
    }

    // MARK: - Between edits

    @Test func aNonEmptyLineKeepsItsSpansBetweenTwoConsecutiveEdits() async throws {
        // Given an analysed line whose next analysis waits out a long debounce
        let editor = Editor("yellow music")
        editor.coordinator.updateColors(editor.textView)
        for _ in 0..<400 where editor.coordinator.appliedColorSpans.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(editor.coordinator.appliedColorSpans.count == 2)
        #expect(editor.textView.becomeFirstResponder())
        editor.textView.selectedRange = NSRange(location: 12, length: 0)
        let musicWidth = try #require(editor.segment("music")).frame.width

        // When two characters are deleted, each followed by the update SwiftUI sends
        editor.deleteBackward()
        let afterFirst = editor.coordinator.appliedColorSpans
        let firstWidth = try #require(editor.underlines.segments.last).frame.width
        editor.coordinator.updateColors(editor.textView)
        editor.deleteBackward()
        let afterSecond = editor.coordinator.appliedColorSpans
        let secondWidth = try #require(editor.underlines.segments.last).frame.width
        editor.coordinator.updateColors(editor.textView)

        // Then the spans were never empty and shrank with the text
        #expect(editor.textView.text == "yellow mus")
        #expect(afterFirst.map(\.range) == [NSRange(location: 0, length: 6), NSRange(location: 7, length: 4)])
        #expect(afterSecond.map(\.range) == [NSRange(location: 0, length: 6), NSRange(location: 7, length: 3)])
        #expect(afterSecond.allSatisfy { $0.underline != nil })
        #expect(editor.underlines.segments.count == 2)
        #expect(firstWidth < musicWidth && secondWidth < firstWidth)
    }

    @Test func spansMoveWithEachKindOfEdit() {
        let red = Color.red
        let spans = [
            LyricsColorSpan(range: NSRange(location: 0, length: 5), foreground: nil, underline: red),  // hello
            LyricsColorSpan(range: NSRange(location: 6, length: 5), foreground: nil, underline: red)   // world
        ]
        func moved(_ range: NSRange, _ replacement: String) -> (ranges: [NSRange], locations: [Int: Int]) {
            let result = LyricsTextView.Coordinator.spansMoved(spans, by: range, replacement: replacement)
            return (result.spans.map(\.range), result.locations)
        }

        // Deleting the last letter shortens the word and shifts the next one.
        #expect(moved(NSRange(location: 4, length: 1), "").ranges == [NSRange(location: 0, length: 4), NSRange(location: 5, length: 5)])
        // Deleting inside a word keeps one span, with no gap.
        #expect(moved(NSRange(location: 2, length: 1), "").ranges == [NSRange(location: 0, length: 4), NSRange(location: 5, length: 5)])
        // A letter typed at the end, inside, or before a word lengthens it at once.
        #expect(moved(NSRange(location: 5, length: 0), "s").ranges == [NSRange(location: 0, length: 6), NSRange(location: 7, length: 5)])
        #expect(moved(NSRange(location: 2, length: 0), "l").ranges == [NSRange(location: 0, length: 6), NSRange(location: 7, length: 5)])
        #expect(moved(NSRange(location: 6, length: 0), "a").ranges == [NSRange(location: 0, length: 5), NSRange(location: 6, length: 6)])
        // A space after a word does not join it; one inside splits it.
        #expect(moved(NSRange(location: 5, length: 0), " ").ranges == [NSRange(location: 0, length: 5), NSRange(location: 7, length: 5)])
        #expect(moved(NSRange(location: 2, length: 0), " ").ranges == [
            NSRange(location: 0, length: 2), NSRange(location: 3, length: 3), NSRange(location: 7, length: 5)
        ])
        // A deleted word loses its span; the next keeps its identity at its new start.
        let deleted = moved(NSRange(location: 0, length: 6), "")
        #expect(deleted.ranges == [NSRange(location: 0, length: 5)])
        #expect(deleted.locations == [6: 0])
    }

    // MARK: - Motion

    @Test func aDeletionEasesTheLineToItsNewWidthOnTheFeedbackTier() async throws {
        let editor = Editor("yellow music")
        await editor.analyse()
        #expect(editor.textView.becomeFirstResponder())
        editor.textView.selectedRange = NSRange(location: 12, length: 0)
        let before = try #require(editor.segment("music"))

        editor.deleteBackward()

        let after = try #require(editor.underlines.segments.last)
        let line = try #require(editor.underlines.line(at: after.location))
        let width = try #require(line.animation(forKey: SyllableUnderlineView.widthAnimationKey) as? CABasicAnimation)
        #expect(width.keyPath == "bounds.size.width")
        #expect(width.fromValue as? CGFloat == before.frame.width)
        #expect(width.toValue as? CGFloat == after.frame.width)
        #expect(width.duration == RhymeAITokens.Motion.feedbackDuration)
        #expect(width.timingFunction == CAMediaTimingFunction(name: .easeOut))
        // The left edge holds still; the line loses about one character's width.
        #expect(line.frame.minX == before.frame.minX)
        #expect(before.frame.width - after.frame.width > 2)
    }

    @Test func aWordThatDisappearsFadesOutAndANewOneGrowsIn() async throws {
        let editor = Editor("yellow a")
        await editor.analyse()
        #expect(editor.textView.becomeFirstResponder())
        editor.textView.selectedRange = NSRange(location: 8, length: 0)
        let gone = try #require(editor.underlines.line(at: 7))

        editor.deleteBackward()

        #expect(editor.underlines.line(at: 7) == nil)
        let fade = try #require(gone.animation(forKey: SyllableUnderlineView.fadeAnimationKey) as? CABasicAnimation)
        #expect(fade.toValue as? Float == 0)
        #expect(fade.duration == RhymeAITokens.Motion.feedbackDuration)

        editor.type("music")
        await editor.analyse()
        let grown = try #require(editor.underlines.line(at: 7))
        let width = try #require(grown.animation(forKey: SyllableUnderlineView.widthAnimationKey) as? CABasicAnimation)
        #expect(width.fromValue as? CGFloat == 0)
    }

    @Test func theFirstLinesOnScreenAppearWithoutGrowing() async throws {
        let editor = Editor("yellow music")

        await editor.analyse()

        let line = try #require(editor.underlines.line(at: 0))
        #expect(line.animationKeys() == nil)
    }

    @Test func reduceMotionSnapsTheLine() async throws {
        let editor = Editor("yellow music")
        editor.underlines.motionEnabled = { false }
        await editor.analyse()
        #expect(editor.textView.becomeFirstResponder())
        editor.textView.selectedRange = NSRange(location: 12, length: 0)

        editor.deleteBackward()

        let after = try #require(editor.underlines.segments.last)
        let line = try #require(editor.underlines.line(at: after.location))
        #expect(line.animationKeys() == nil)
        #expect(line.frame == after.frame)
    }
}
