#if os(macOS)
import SwiftUI

// Stand-ins that let the screens shared with iOS keep their iOS-only
// navigation-bar and keyboard modifiers without an `#if` at every call site.
// On macOS each one is a no-op or the matching window-toolbar placement.

enum NavigationBarTitleDisplayModeShim {
    case automatic, inline, large
}

enum TextInputAutocapitalizationShim {
    case never, words, sentences, characters
}

extension View {
    /// A Mac window's toolbar has no large-title mode.
    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayModeShim) -> some View { self }

    /// A Mac window has no navigation bar to hide.
    func navigationBarHidden(_ hidden: Bool) -> some View { self }

    /// A Mac keyboard has no automatic capitalization to configure.
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalizationShim?) -> some View { self }
}

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

extension ToolbarPlacement {
    static var navigationBar: ToolbarPlacement { .windowToolbar }
}
#endif
