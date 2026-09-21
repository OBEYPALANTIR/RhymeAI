import AppKit
import SwiftUI

struct MacLyricsTextView: NSViewRepresentable {
    @ObservedObject var editor: EditorViewModel
    let appearance: AppAppearanceStyle

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let text = MacLyricsNSTextView()
        text.lyricsUndoManager = LyricsHistoryUndoManager(editor: editor)
        text.allowsUndo = false
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isContinuousSpellCheckingEnabled = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 24, height: 20)
        text.minSize = NSSize(width: 0, height: 400)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.font = .systemFont(ofSize: 17)
        text.defaultParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 9
            return style
        }()
        text.delegate = context.coordinator
        text.setAccessibilityLabel("Lyrics")
        text.setAccessibilityIdentifier("macLyricsEditor")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if text.string != editor.lyrics {
            text.string = editor.lyrics
        }
        let range = editor.selectedRange
        let length = text.string.utf16.count
        let location = min(max(0, range.location), length)
        let selection = NSRange(location: location, length: min(max(0, range.length), length - location))
        if text.selectedRange() != selection && !text.hasMarkedText() {
            text.setSelectedRange(selection)
            text.scrollRangeToVisible(selection)
        }
        text.backgroundColor = NSColor(appearance.palette.canvas)
        text.textColor = NSColor(appearance.palette.primaryInk)
        text.insertionPointColor = NSColor(appearance.palette.caret)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let editor: EditorViewModel
        var updating = false
        init(editor: EditorViewModel) { self.editor = editor }
        func textDidChange(_ notification: Notification) {
            guard !updating, let text = notification.object as? NSTextView else { return }
            editor.onLyricsChanged(text.string)
            editor.selectedRange = text.selectedRange()
            editor.cursorPosition = text.selectedRange().location
            editor.triggerAutoSave()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let text = notification.object as? NSTextView else { return }
            editor.selectedRange = text.selectedRange()
            editor.cursorPosition = text.selectedRange().location
        }
    }
}

final class LyricsHistoryUndoManager: UndoManager {
    weak var editor: EditorViewModel?
    init(editor: EditorViewModel) { self.editor = editor; super.init() }
    override var canUndo: Bool { editor?.canUndoLyrics ?? false }
    override var canRedo: Bool { editor?.canRedoLyrics ?? false }
    override func undo() { editor?.undoLyrics() }
    override func redo() { editor?.redoLyrics() }
}

final class MacLyricsNSTextView: NSTextView {
    var lyricsUndoManager: LyricsHistoryUndoManager?
    override var undoManager: UndoManager? { lyricsUndoManager }
}
