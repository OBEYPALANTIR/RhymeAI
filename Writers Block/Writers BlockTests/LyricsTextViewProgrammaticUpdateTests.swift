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
}
