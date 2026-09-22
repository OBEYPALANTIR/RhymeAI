import Foundation
import UIKit
import SwiftUI
import SwiftData
import Testing
@testable import Writers_Block

@MainActor
struct EditorUndoRedoTests {
    @Test
    func typingCanBeUndoneAndRedone() {
        let viewModel = EditorViewModel()
        viewModel.newProject()
        viewModel.onLyricsChanged("first line", timestampMilliseconds: 0)

        viewModel.undoLyrics()

        #expect(viewModel.lyrics == "")
        #expect(viewModel.canRedoLyrics)

        viewModel.redoLyrics()

        #expect(viewModel.lyrics == "first line")
        #expect(viewModel.canUndoLyrics)
    }

    @Test
    func insertedSuggestionIsOneUndoableEdit() {
        let viewModel = EditorViewModel()
        viewModel.newProject()
        viewModel.lyrics = "opening line"
        viewModel.cursorPosition = viewModel.lyrics.utf16.count

        viewModel.insertSuggestion("next line")
        viewModel.undoLyrics()

        #expect(viewModel.lyrics == "opening line")
    }

    @Test
    func loadingAnotherProjectClearsHistory() throws {
        let (viewModel, container) = try makeStoredEditor()
        defer { withExtendedLifetime(container) {} }
        viewModel.newProject()
        viewModel.onLyricsChanged("temporary draft", timestampMilliseconds: 0)

        viewModel.loadProject(SongProject(title: "Loaded", lyrics: "saved lyrics"))

        #expect(!viewModel.canUndoLyrics)
        #expect(!viewModel.canRedoLyrics)
    }

    @Test
    func suggestionFeedbackUsesUTF16AndUndoRestoresSelection() {
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore())
        viewModel.newProject()
        viewModel.lyrics = "🌙 opening\ntail"
        viewModel.cursorPosition = "🌙 opening".utf16.count
        viewModel.selectedRange = NSRange(location: 3, length: 7)

        viewModel.insertSuggestion("A quiet light")

        #expect(viewModel.insertedLineRange == NSRange(location: 11, length: 13))
        #expect(viewModel.insertionFeedbackID != nil)
        #expect(viewModel.lyrics == "🌙 opening\nA quiet light\n\ntail")
        viewModel.undoInsertedLine()
        #expect(viewModel.lyrics == "🌙 opening\ntail")
        #expect(viewModel.selectedRange == NSRange(location: 3, length: 7))
        #expect(viewModel.cursorPosition == 10)
        #expect(viewModel.insertionFeedbackID == nil)
    }

    @Test
    func editingAfterInsertionInvalidatesItsUndoFeedback() {
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore())
        viewModel.newProject()
        viewModel.insertSuggestion("A quiet light")
        let edited = viewModel.lyrics + "My next line"
        viewModel.onLyricsChanged(edited)

        #expect(viewModel.insertionFeedbackID == nil)
        #expect(viewModel.insertedLineRange == nil)
        viewModel.undoInsertedLine()
        #expect(viewModel.lyrics == edited)
    }

    @Test
    func songSwitchAndHistoryClearInsertionFeedback() throws {
        let (viewModel, container) = try makeStoredEditor()
        defer { withExtendedLifetime(container) {} }
        viewModel.newProject()
        viewModel.insertSuggestion("A quiet light")
        viewModel.undoLyrics()
        viewModel.redoLyrics()
        #expect(viewModel.insertionFeedbackID == nil)
        viewModel.insertSuggestion("Another light")
        viewModel.newProject()
        #expect(viewModel.insertionFeedbackID == nil)
    }

    @Test
    func autosaveDoesNotReportSuccessForMissingSong() async throws {
        let (viewModel, container) = try makeStoredEditor()
        defer { withExtendedLifetime(container) {} }
        viewModel.newProject()
        viewModel.currentProjectId = "missing-song"
        viewModel.onLyricsChanged("Keep these lyrics")
        viewModel.triggerAutoSave()
        try await Task.sleep(for: .milliseconds(1300))
        #expect(viewModel.saveStatus == .failed)
        #expect(viewModel.companionError != nil)
        viewModel.saveCompanion(checkpoint: false)
        #expect(viewModel.saveStatus == .failed)
        #expect(viewModel.lyrics == "Keep these lyrics")
    }

    private func makeStoredEditor() throws -> (EditorViewModel, ModelContainer) {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), companionStore: WritingCompanionStore(inMemory: true))
        viewModel.modelContext = ModelContext(container)
        return (viewModel, container)
    }
}

@MainActor
struct LyricsCaretLayoutTests {
    @Test
    func localTypingDoesNotReapplyStaleSelection() {
        let parent = LyricsTextView(text: .constant(""), onCursorChange: { _ in })
        let coordinator = parent.makeCoordinator()
        #expect(coordinator.shouldApplySelection(NSRange(location: 0, length: 0)))
        let view = UITextView()
        view.text = "t"
        view.selectedRange = NSRange(location: 1, length: 0)
        coordinator.textViewDidChange(view)
        #expect(!coordinator.shouldApplySelection(NSRange(location: 0, length: 0)))
        #expect(!coordinator.shouldApplySelection(NSRange(location: 1, length: 0)))
        #expect(coordinator.shouldApplySelection(NSRange(location: 0, length: 0)))
        #expect(coordinator.shouldApplySelection(NSRange(location: 1, length: 0)))
    }

    @Test
    func bindingEchoDoesNotOverwriteInFlightTyping() {
        let coordinator = LyricsTextView(text: .constant(""), onCursorChange: { _ in }).makeCoordinator()
        #expect(coordinator.shouldApplyText(""))
        let view = UITextView()
        view.text = "R"
        coordinator.textViewDidChange(view)
        view.text = "RE"
        #expect(!coordinator.shouldApplyText("R"))
        coordinator.textViewDidChange(view)
        #expect(!coordinator.shouldApplyText("RE"))
        #expect(coordinator.shouldApplyText("external replacement"))
        #expect(coordinator.shouldApplyText("RE"))
    }

    @Test
    func coloringPreservesCaretWrappingAndSelection() async {
        let text = "The last word is light tonight\nA melody carries through the night\tlight 👩🏽‍🎤 café"
        for width: CGFloat in [180, 350, 700] {
            let view = UITextView(usingTextLayoutManager: true)
            view.frame = CGRect(x: 0, y: 0, width: width, height: 500)
            view.font = .systemFont(ofSize: 16)
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.text = text
            view.selectedRange = NSRange(location: text.utf16.count, length: 0)
            view.layoutIfNeeded()
            let positions = (0...text.utf16.count).compactMap { view.position(from: view.beginningOfDocument, offset: $0) }
            let before = positions.map { view.caretRect(for: $0) }
            for (rhyme, syllables) in [(false, true), (true, false), (true, true), (false, false)] {
                let spans = await LyricsHighlighting.spans(text: text, rhymeEnabled: rhyme,
                                                          syllablesEnabled: syllables, isDark: false)
                LyricsTextView.Coordinator.applyColors(spans, to: view, foreground: .black)
                view.layoutIfNeeded()
                #expect(view.text == text)
                #expect(view.selectedRange == NSRange(location: text.utf16.count, length: 0))
                #expect(positions.map { view.caretRect(for: $0) } == before)
            }
            view.insertText("s")
            #expect(view.text == text + "s")
            #expect(view.selectedRange.location == text.utf16.count + 1)
        }
    }

    @Test
    func deletionKeepsShiftedWordColoredBeforeAnalysisCompletes() async throws {
        let text = "light night"
        let coordinator = LyricsTextView(
            text: .constant(text),
            onCursorChange: { _ in },
            syllableColoringEnabled: true
        ).makeCoordinator()
        let view = UITextView(usingTextLayoutManager: true)
        view.frame = CGRect(x: 0, y: 0, width: 420, height: 100)
        view.font = .monospacedSystemFont(ofSize: 36, weight: .regular)
        view.backgroundColor = .white
        view.textColor = .black
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.text = text
        coordinator.attach(to: view)
        let spans = await LyricsHighlighting.spans(
            text: text,
            rhymeEnabled: false,
            syllablesEnabled: true,
            isDark: false
        )
        coordinator.installColors(spans, for: text, on: view, foreground: .black)
        #expect(try saturatedPixelCount(in: renderedImage(of: view), view: view, offset: 6) > 4)

        #expect(coordinator.textView(
            view,
            shouldChangeTextIn: NSRange(location: 0, length: 1),
            replacementText: ""
        ))
        view.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        coordinator.textViewDidChange(view)

        let image = renderedImage(of: view)
        let coloredPixels = try saturatedPixelCount(in: image, view: view, offset: 5)
        if let directory = ProcessInfo.processInfo.environment["RHYMEAI_HIGHLIGHT_EVIDENCE_DIR"],
           let data = image.pngData() {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("deletion-immediate-current.png"))
        }
        #expect(coloredPixels > 4, "The shifted word must retain its color in the first TextKit 2 render after deletion.")

        coordinator.updateColors(view)
        try await waitForColoredGlyph(in: view, offset: 5)
        #expect(view.text == "ight night")
    }

    @Test
    func immediateColorReconciliationHandlesUTF16NewlinesSelectionsAndModes() async throws {
        let scenarios: [(text: String, deletion: NSRange, result: String, oldTarget: Int, newTarget: Int)] = [
            ("🌙 light night", NSRange(location: 0, length: 3), "light night", 9, 6),
            ("light\nnight", NSRange(location: 5, length: 1), "lightnight", 6, 5),
            ("light\nnight", NSRange(location: 0, length: 6), "night", 6, 0)
        ]
        let modes = [
            (rhyme: false, syllables: true),
            (rhyme: true, syllables: false),
            (rhyme: true, syllables: true)
        ]

        for scenario in scenarios {
            for mode in modes {
                let coordinator = LyricsTextView(
                    text: .constant(scenario.text),
                    onCursorChange: { _ in },
                    rhymeHighlightEnabled: mode.rhyme,
                    syllableColoringEnabled: mode.syllables
                ).makeCoordinator()
                let view = configuredTextView(text: scenario.text)
                coordinator.attach(to: view)
                let spans = await LyricsHighlighting.spans(
                    text: scenario.text,
                    rhymeEnabled: mode.rhyme,
                    syllablesEnabled: mode.syllables,
                    isDark: false
                )
                coordinator.installColors(spans, for: scenario.text, on: view, foreground: .black)
                #expect(try saturatedPixelCount(
                    in: renderedImage(of: view), view: view, offset: scenario.oldTarget
                ) > 4)

                #expect(coordinator.textView(
                    view,
                    shouldChangeTextIn: scenario.deletion,
                    replacementText: ""
                ))
                view.textStorage.replaceCharacters(in: scenario.deletion, with: "")
                let selectionBeforeRepaint = view.selectedRange
                coordinator.textViewDidChange(view)

                #expect(view.text == scenario.result)
                #expect(view.selectedRange == selectionBeforeRepaint)
                #expect(try saturatedPixelCount(
                    in: renderedImage(of: view), view: view, offset: scenario.newTarget
                ) > 4)
            }
        }

        let coordinator = LyricsTextView(
            text: .constant("light night"),
            onCursorChange: { _ in }
        ).makeCoordinator()
        let view = configuredTextView(text: "light night")
        coordinator.attach(to: view)
        coordinator.installColors([], for: view.text, on: view, foreground: .black)
        #expect(coordinator.textView(
            view,
            shouldChangeTextIn: NSRange(location: 0, length: 1),
            replacementText: ""
        ))
        view.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        coordinator.textViewDidChange(view)
        #expect(try saturatedPixelCount(in: renderedImage(of: view), view: view, offset: 5) == 0)
    }

    @Test
    func completedAnalysisReplacesPreservedColorWithCurrentRhymeSemantics() async throws {
        let text = "light night"
        let coordinator = LyricsTextView(
            text: .constant(text),
            onCursorChange: { _ in },
            rhymeHighlightEnabled: true
        ).makeCoordinator()
        let view = configuredTextView(text: text)
        coordinator.attach(to: view)
        let spans = await LyricsHighlighting.spans(
            text: text,
            rhymeEnabled: true,
            syllablesEnabled: false,
            isDark: false
        )
        coordinator.installColors(spans, for: text, on: view, foreground: .black)
        #expect(try saturatedPixelCount(in: renderedImage(of: view), view: view, offset: 6) > 4)

        #expect(coordinator.textView(
            view,
            shouldChangeTextIn: NSRange(location: 0, length: 6),
            replacementText: ""
        ))
        view.textStorage.replaceCharacters(in: NSRange(location: 0, length: 6), with: "")
        coordinator.textViewDidChange(view)
        #expect(try saturatedPixelCount(in: renderedImage(of: view), view: view, offset: 0) > 4)

        let settledSpans = await LyricsHighlighting.spans(
            text: "night",
            rhymeEnabled: true,
            syllablesEnabled: false,
            isDark: false
        )
        #expect(settledSpans.allSatisfy { $0.foreground == nil })
        coordinator.updateColors(view)
        for _ in 0..<500 {
            if try saturatedPixelCount(in: renderedImage(of: view), view: view, offset: 0) == 0 {
                #expect(view.text == "night")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Expected completed rhyme analysis to return the unpaired word to base ink.")
    }

    private func configuredTextView(text: String) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.frame = CGRect(x: 0, y: 0, width: 420, height: 100)
        view.font = .monospacedSystemFont(ofSize: 36, weight: .regular)
        view.backgroundColor = .white
        view.textColor = .black
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.text = text
        return view
    }

    private func waitForColoredGlyph(in view: UITextView, offset: Int) async throws {
        for _ in 0..<500 {
            let image = renderedImage(of: view)
            if try saturatedPixelCount(in: image, view: view, offset: offset) > 4 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Expected TextKit 2 to render a colored glyph at UTF-16 offset \(offset).")
    }

    private func renderedImage(of view: UITextView) -> UIImage {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if let layout = view.textLayoutManager, let content = layout.textContentManager {
            layout.ensureLayout(for: content.documentRange)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    private func saturatedPixelCount(in image: UIImage, xRange: Range<CGFloat>) -> Int {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        let minX = max(Int(xRange.lowerBound * image.scale), 0)
        let maxX = min(Int(ceil(xRange.upperBound * image.scale)), cgImage.width)
        var count = 0
        for y in 0..<cgImage.height {
            for x in minX..<maxX {
                let offset = y * cgImage.bytesPerRow + x * 4
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                if max(red, green, blue) - min(red, green, blue) > 28 { count += 1 }
            }
        }
        return count
    }

    private func saturatedPixelCount(in image: UIImage, view: UITextView, offset: Int) throws -> Int {
        let start = try #require(view.position(from: view.beginningOfDocument, offset: offset))
        let end = try #require(view.position(from: start, offset: 1))
        return saturatedPixelCount(
            in: image,
            xRange: view.caretRect(for: start).minX..<view.caretRect(for: end).minX
        )
    }
}
