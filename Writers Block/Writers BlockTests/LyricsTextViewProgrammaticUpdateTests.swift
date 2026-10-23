import SwiftUI
import Testing
import UIKit
@testable import Writers_Block

struct LyricsTextViewProgrammaticUpdateTests {
    @Test @MainActor
    func programmaticTextUpdateDoesNotPublishSelectionChanges() {
        // Given
        var boundText = "first line"
        var cursorChangeCount = 0
        let parent = LyricsTextView(
            text: Binding(
                get: { boundText },
                set: { boundText = $0 }
            ),
            onCursorChange: { _ in cursorChangeCount += 1 }
        )
        let coordinator = parent.makeCoordinator()
        let textView = UITextView()
        textView.delegate = coordinator
        coordinator.attach(to: textView)

        let viewController = UIViewController()
        viewController.view.addSubview(textView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        #expect(textView.becomeFirstResponder())

        // When
        coordinator.updateRenderedText("", in: textView)

        // Then
        #expect(cursorChangeCount == 0)
    }

    @Test @MainActor
    func sectionLabelsRenderQuietlyWithoutChangingStoredTextOrLyricColours() throws {
        // Given
        let text = "[Verse 1]\nyellow music\n\n[Chorus]\nhold the line"
        let textView = UITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        textView.text = text
        let storedBefore = NSAttributedString(attributedString: textView.textStorage)
        let ink = UIColor.black
        let quiet = UIColor.gray
        let nsText = text as NSString
        let yellow = nsText.range(of: "yellow")

        // When
        LyricsTextView.Coordinator.applyColors(
            [LyricsColorSpan(range: yellow, foreground: .red, underline: nil)],
            to: textView,
            foreground: ink,
            sectionLabelForeground: quiet
        )

        // Then
        let layout = try #require(textView.textLayoutManager)
        let content = try #require(layout.textContentManager)
        func colour(at offset: Int) -> UIColor? {
            guard let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
            var found: UIColor?
            layout.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
                found = attributes[.foregroundColor] as? UIColor
                return false
            }
            return found
        }
        #expect(colour(at: nsText.range(of: "[Verse 1]").location) == quiet)
        #expect(colour(at: nsText.range(of: "Chorus").location) == quiet)
        #expect(colour(at: nsText.range(of: "music").location) == ink)
        #expect(colour(at: nsText.range(of: "line").location) == ink)
        let lyricColour = try #require(colour(at: yellow.location))
        #expect(lyricColour != quiet)
        #expect(lyricColour != ink)
        #expect(textView.text == text)
        #expect(storedBefore.isEqual(to: textView.textStorage))
    }

    @Test @MainActor
    func rewriteHighlightRedrawsWhenTheAppearanceChanges() {
        // Given
        let coordinator = LyricsTextView(text: .constant("first line"), onCursorChange: { _ in }).makeCoordinator()
        let highlight = LyricsRewriteHighlight(range: NSRange(location: 0, length: 5), isLoading: false, isError: false)
        #expect(coordinator.shouldUpdateRewriteHighlight(textChanged: false, highlight: highlight, appearance: .ink))
        #expect(!coordinator.shouldUpdateRewriteHighlight(textChanged: false, highlight: highlight, appearance: .ink))

        // When
        let redraws = coordinator.shouldUpdateRewriteHighlight(textChanged: false, highlight: highlight, appearance: .graphite)

        // Then
        #expect(redraws)
    }
}
