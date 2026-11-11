import SwiftUI
import Testing
import UIKit
@testable import Writers_Block

/// The editor lays the lyrics out in a scroll view at the column width. Lines
/// that wrap there must count toward the height, or the last lines are never
/// reachable.
@MainActor
struct LyricsTextViewSizingTests {
    @Test
    func wrappedLinesCountTowardTheHeightAtTheColumnWidth() throws {
        let longLine = "We were dancing on the hood of a car that your brother swore he would fix before the end of the year"
        let lyrics = (Array(repeating: longLine, count: 12) + ["Last line of the song"]).joined(separator: "\n")
        let width: CGFloat = 320
        let host = UIHostingController(rootView: ScrollView {
            LyricsTextView(text: .constant(lyrics), onCursorChange: { _ in })
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 640))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        let textView = try #require(Self.lyricsTextView(in: host.view))
        let wrappedHeight = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let lineHeight = try #require(textView.font?.lineHeight)

        #expect(textView.bounds.width == width)
        // Every long line wraps at least once at this width.
        #expect(wrappedHeight > lineHeight * 24)
        #expect(textView.bounds.height >= wrappedHeight - 0.5)
    }

    private static func lyricsTextView(in view: UIView) -> UITextView? {
        if let textView = view as? LyricsUITextView { return textView }
        return view.subviews.lazy.compactMap(lyricsTextView(in:)).first
    }
}
