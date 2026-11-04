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

        // And one undo takes back the typing itself, not an underline
        undoManager.undo()
        #expect(textView.text == "")
        #expect(boundText == "")
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

    @Test func linesFollowTextComposedBeforeThemAndKeepTheComposition() async throws {
        // Given an underlined line and a composition starting before its first word
        let editor = Editor("yellow music")
        editor.underlines.motionEnabled = { false }
        await editor.analyse()
        #expect(editor.textView.becomeFirstResponder())
        editor.textView.selectedRange = NSRange(location: 0, length: 0)

        // When kana are composed there
        editor.textView.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0))
        try #require(editor.textView.markedTextRange != nil)

        // Then each line has moved with its word while the composition stays open
        let yellow = try #require(editor.underlines.segments.first { $0.location == 2 })
        let music = try #require(editor.underlines.segments.first { $0.location == 9 })
        let yellowWord = try #require(editor.wordRect(at: 2, length: 6))
        let musicWord = try #require(editor.wordRect(at: 9, length: 5))
        #expect(abs(yellow.frame.minX - yellowWord.minX) < 1)
        #expect(abs(music.frame.minX - musicWord.minX) < 1)
        #expect(editor.textView.markedTextRange != nil)
        #expect(!storageHasUnderline(editor.textView))

        // And committing keeps them there
        editor.textView.unmarkText()
        #expect(editor.textView.text == "にほyellow music")
        #expect(abs((editor.underlines.segments.first { $0.location == 2 }?.frame.minX ?? -1) - yellowWord.minX) < 1)
    }

    @Test func linesReWrapUnderTheirWordsWhenTheWidthChanges() async throws {
        // Given a line that wraps "follow" onto a second row at a narrow width
        let editor = Editor("yellow music follow")
        editor.underlines.motionEnabled = { false }
        editor.textView.frame.size.width = 130
        editor.textView.layoutIfNeeded()
        await editor.analyse()
        let narrowYellow = try #require(editor.segment("yellow"))
        let narrowFollow = try #require(editor.segment("follow"))
        #expect(narrowFollow.frame.minY > narrowYellow.frame.minY)

        // When the width grows enough for one row
        editor.textView.frame.size.width = 320
        editor.textView.layoutIfNeeded()

        // Then every line sits under its word again, without re-analysis
        let follow = try #require(editor.segment("follow"))
        let followWord = try #require(editor.wordRect(at: follow.location, length: 6))
        #expect(follow.frame.minY == narrowYellow.frame.minY)
        #expect(abs(follow.frame.minX - followWord.minX) < 1)
        #expect(abs(follow.frame.width - followWord.width) < 1)
        #expect(editor.underlines.line(at: follow.location)?.frame == follow.frame)
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

    @Test func aReplacementAcrossTwoWordsKeepsTheSurvivingLine() async throws {
        // "hello world": replacing "lo wo" with "x" leaves "helxrld".
        let spans = [
            LyricsColorSpan(range: NSRange(location: 0, length: 5), foreground: nil, underline: .red),
            LyricsColorSpan(range: NSRange(location: 6, length: 5), foreground: nil, underline: .blue)
        ]
        let moved = LyricsTextView.Coordinator.spansMoved(spans, by: NSRange(location: 3, length: 5), replacement: "x")
        #expect(moved.spans.map(\.range) == [NSRange(location: 0, length: 4), NSRange(location: 4, length: 3)])
        #expect(moved.locations == [0: 0, 6: 4])

        // The same edit in the editor keeps the "world" line's layer.
        let editor = Editor("hello world")
        await editor.analyse()
        let world = try #require(editor.underlines.line(at: 6))
        #expect(editor.textView.becomeFirstResponder())
        editor.textView.selectedRange = NSRange(location: 3, length: 5)
        editor.type("x")
        #expect(editor.textView.text == "helxrld")
        #expect(editor.underlines.line(at: 4) === world)
        #expect(world.animation(forKey: SyllableUnderlineView.fadeAnimationKey) == nil)
    }

    @Test func anEditTheDelegateWasNotAskedAboutStillMovesTheLines() {
        let edit = LyricsTextView.Coordinator.edit(from: "yellow music", to: "yellow musi")
        #expect(edit.range == NSRange(location: 11, length: 1))
        #expect(edit.replacement == "")
        let inserted = LyricsTextView.Coordinator.edit(from: "yellow music", to: "にほyellow music")
        #expect(inserted.range == NSRange(location: 0, length: 0))
        #expect(inserted.replacement == "にほ")
    }

    @Test func twoSeparateEditsTheDelegateMissedKeepTheWordBetweenThem() {
        // "yellow music follow" -> "ellow music ollow": a letter gone from each end word.
        let spans = [
            LyricsColorSpan(range: NSRange(location: 0, length: 6), foreground: nil, underline: .red),
            LyricsColorSpan(range: NSRange(location: 7, length: 5), foreground: nil, underline: .blue),
            LyricsColorSpan(range: NSRange(location: 13, length: 6), foreground: nil, underline: .green)
        ]
        let moved = LyricsTextView.Coordinator.spansMoved(spans, from: "yellow music follow", to: "ellow music ollow")
        #expect(moved.spans.map(\.range) == [
            NSRange(location: 0, length: 5), NSRange(location: 6, length: 5), NSRange(location: 12, length: 5)
        ])
        #expect(moved.spans.map(\.underline) == [.red, .blue, .green])
        #expect(moved.locations == [0: 0, 7: 6, 13: 12])
    }

    @Test func anAutocorrectionAndASpaceKeepTheWholeWordUnderlined() {
        // "yellow musci" -> "yellow music ": the corrected word keeps its span, at its full length.
        let spans = [
            LyricsColorSpan(range: NSRange(location: 0, length: 6), foreground: nil, underline: .red),
            LyricsColorSpan(range: NSRange(location: 7, length: 5), foreground: nil, underline: .blue)
        ]
        let moved = LyricsTextView.Coordinator.spansMoved(spans, from: "yellow musci", to: "yellow music ")
        #expect(moved.spans.map(\.range) == [NSRange(location: 0, length: 6), NSRange(location: 7, length: 5)])
        #expect(moved.locations == [0: 0, 7: 7])
    }

    @Test func aWordTheDelegateMissedDeletingLosesOnlyItsOwnSpan() {
        let spans = [
            LyricsColorSpan(range: NSRange(location: 0, length: 6), foreground: nil, underline: .red),
            LyricsColorSpan(range: NSRange(location: 7, length: 5), foreground: nil, underline: .blue),
            LyricsColorSpan(range: NSRange(location: 13, length: 6), foreground: nil, underline: .green)
        ]
        let moved = LyricsTextView.Coordinator.spansMoved(spans, from: "yellow music follow", to: "yellow follow")
        #expect(moved.spans.map(\.range) == [NSRange(location: 0, length: 6), NSRange(location: 7, length: 6)])
        #expect(moved.locations == [0: 0, 13: 7])
    }

    @Test func splitsJoinsAndReplacementsTheDelegateMissedKeepTheSurvivingCharacters() {
        let yellowMusic = [
            LyricsColorSpan(range: NSRange(location: 0, length: 6), foreground: nil, underline: .red),
            LyricsColorSpan(range: NSRange(location: 7, length: 5), foreground: nil, underline: .blue)
        ]
        func moved(_ spans: [LyricsColorSpan], _ old: String, _ new: String) -> (ranges: [NSRange], underlines: [Color?], locations: [Int: Int]) {
            let result = LyricsTextView.Coordinator.spansMoved(spans, from: old, to: new)
            return (result.spans.map(\.range), result.spans.map(\.underline), result.locations)
        }

        // A split: both halves of "yellow" keep its colour; "music" shifts.
        let split = moved(yellowMusic, "yellow music", "yel low music")
        #expect(split.ranges == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3), NSRange(location: 8, length: 5)])
        #expect(split.underlines == [.red, .red, .blue])
        #expect(split.locations == [0: 0, 7: 8])

        // A join: each word's characters keep their own colour inside the joined word.
        let join = moved(yellowMusic, "yellow music", "yellowmusic")
        #expect(join.ranges == [NSRange(location: 0, length: 6), NSRange(location: 6, length: 5)])
        #expect(join.underlines == [.red, .blue])
        #expect(join.locations == [0: 0, 7: 6])

        // A replacement across the space: both surviving fragments stay.
        let helloWorld = [
            LyricsColorSpan(range: NSRange(location: 0, length: 5), foreground: nil, underline: .red),
            LyricsColorSpan(range: NSRange(location: 6, length: 5), foreground: nil, underline: .blue)
        ]
        let replaced = moved(helloWorld, "hello world", "helxrld")
        #expect(replaced.ranges == [NSRange(location: 0, length: 4), NSRange(location: 4, length: 3)])
        #expect(replaced.underlines == [.red, .blue])
        #expect(replaced.locations == [0: 0, 6: 4])

        // A split, then its undo: the line runs unbroken under the rejoined word.
        let splitSpans = zip(split.ranges, split.underlines).map {
            LyricsColorSpan(range: $0.0, foreground: nil, underline: $0.1)
        }
        let undone = moved(splitSpans, "yel low music", "yellow music")
        #expect(undone.ranges == [NSRange(location: 0, length: 3), NSRange(location: 3, length: 3), NSRange(location: 7, length: 5)])
        #expect(undone.underlines == [.red, .red, .blue])
        #expect(undone.locations == [0: 0, 4: 3, 8: 7])
    }

    @Test func editsOnTwoLinesTheDelegateMissedEachKeepTheirOwnCharacters() async throws {
        // "yellow" is split on the first line and "follow" loses its "f" on the second.
        let old = "yellow music\nfollow music"
        let new = "yel low music\nollow music"
        let spans = [
            LyricsColorSpan(range: NSRange(location: 0, length: 6), foreground: nil, underline: .red),
            LyricsColorSpan(range: NSRange(location: 7, length: 5), foreground: nil, underline: .blue),
            LyricsColorSpan(range: NSRange(location: 13, length: 6), foreground: nil, underline: .green),
            LyricsColorSpan(range: NSRange(location: 20, length: 5), foreground: nil, underline: .purple)
        ]
        let moved = LyricsTextView.Coordinator.spansMoved(spans, from: old, to: new)
        #expect(moved.spans.map(\.range) == [
            NSRange(location: 0, length: 3), NSRange(location: 4, length: 3), NSRange(location: 8, length: 5),
            NSRange(location: 14, length: 5), NSRange(location: 20, length: 5)
        ])
        #expect(moved.spans.map(\.underline) == [.red, .red, .blue, .green, .purple])
        #expect(moved.locations == [0: 0, 7: 8, 13: 14, 20: 20])

        // In the editor, every surviving line keeps its layer through the same edit.
        let editor = Editor(old)
        await editor.analyse()
        let layers = (editor.underlines.line(at: 0), editor.underlines.line(at: 7),
                      editor.underlines.line(at: 13), editor.underlines.line(at: 20))
        editor.textView.text = new
        editor.coordinator.textViewDidChange(editor.textView)
        #expect(editor.underlines.line(at: 0) === layers.0)
        #expect(editor.underlines.line(at: 8) === layers.1)
        #expect(editor.underlines.line(at: 14) === layers.2)
        #expect(editor.underlines.line(at: 20) === layers.3)
        #expect(editor.underlines.line(at: 4) != nil)
    }

    @Test func repeatedWordsEditedAtBothEndsKeepTheirPlaces() {
        let spans = [0, 3, 6, 9].map {
            LyricsColorSpan(range: NSRange(location: $0, length: 2), foreground: nil, underline: .red)
        }
        let moved = LyricsTextView.Coordinator.spansMoved(spans, from: "la la\nla la", to: "lo la\nla le")
        #expect(moved.spans.map(\.range) == [0, 3, 6, 9].map { NSRange(location: $0, length: 2) })
        #expect(moved.locations == [0: 0, 3: 3, 6: 6, 9: 9])
    }

    @Test func anUnchangedWordAnchorsBeforeCharactersAreAligned() {
        // "cat yellow dog" -> "yellowish yellow cat": only "yellow" survives as itself.
        let spans = [
            LyricsColorSpan(range: NSRange(location: 0, length: 3), foreground: nil, underline: .red),
            LyricsColorSpan(range: NSRange(location: 4, length: 6), foreground: nil, underline: .blue),
            LyricsColorSpan(range: NSRange(location: 11, length: 3), foreground: nil, underline: .green)
        ]
        let moved = LyricsTextView.Coordinator.spansMoved(spans, from: "cat yellow dog", to: "yellowish yellow cat")
        #expect(moved.spans.map(\.range) == [NSRange(location: 10, length: 6)])
        #expect(moved.spans.map(\.underline) == [.blue])
        #expect(moved.locations == [4: 10])
    }

    @Test func aReplacementTooLargeToAlignColoursNothingItDidNotKeep() {
        let spans = [LyricsColorSpan(range: NSRange(location: 0, length: 501), foreground: nil, underline: .red)]
        let moved = LyricsTextView.Coordinator.spansMoved(
            spans, from: String(repeating: "a", count: 501), to: String(repeating: "b", count: 500)
        )
        #expect(moved.spans.isEmpty)
        #expect(moved.locations.isEmpty)
    }

    @Test(arguments: [499, 2_000])
    func manyUnchangedWordsBetweenTwoEditsAllKeepTheirSpans(count: Int) {
        let old = "yellow " + String(repeating: "music ", count: count) + "follow"
        let new = "xellow " + String(repeating: "music ", count: count) + "follot"
        let last = 7 + 6 * count
        let locations = [0] + (0..<count).map { 7 + 6 * $0 } + [last]
        let spans = locations.map {
            LyricsColorSpan(range: NSRange(location: $0, length: $0 == 0 || $0 == last ? 6 : 5), foreground: nil, underline: .red)
        }
        let moved = LyricsTextView.Coordinator.spansMoved(spans, from: old, to: new)
        #expect(moved.spans.map(\.range) == spans.map(\.range))
        #expect(moved.locations == Dictionary(uniqueKeysWithValues: locations.map { ($0, $0) }))
    }

    @Test func fragmentsAJoinLeftStillAnchorTheirWord() {
        // "cat yel low dog": the space is deleted, then before any analysis
        // the line is rewritten around the joined word.
        let spans = [
            LyricsColorSpan(range: NSRange(location: 0, length: 3), foreground: nil, underline: .red),
            LyricsColorSpan(range: NSRange(location: 4, length: 3), foreground: nil, underline: .blue),
            LyricsColorSpan(range: NSRange(location: 8, length: 3), foreground: nil, underline: .purple),
            LyricsColorSpan(range: NSRange(location: 12, length: 3), foreground: nil, underline: .green)
        ]
        let joined = LyricsTextView.Coordinator.spansMoved(spans, by: NSRange(location: 7, length: 1), replacement: "")
        #expect(joined.spans.map(\.range) == [
            NSRange(location: 0, length: 3), NSRange(location: 4, length: 3),
            NSRange(location: 7, length: 3), NSRange(location: 11, length: 3)
        ])

        let moved = LyricsTextView.Coordinator.spansMoved(joined.spans, from: "cat yellow dog", to: "yellowish yellow cat")

        #expect(moved.spans.map(\.range) == [NSRange(location: 10, length: 3), NSRange(location: 13, length: 3)])
        #expect(moved.spans.map(\.underline) == [.blue, .purple])
        #expect(moved.locations == [4: 10, 7: 13])
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
