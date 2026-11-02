#if os(macOS)
import SwiftUI

// The Mac app runs the iPad layout. These stand-ins let the shared views keep
// their iOS-only modifiers without an `#if` at every call site; on macOS each
// one is the regular-width value or a no-op.

/// macOS has no size classes; every Mac window is laid out as regular width,
/// and `RhymeAITokens.Layout.fitsSideColumn` still decides the side column.
enum UserInterfaceSizeClass: Hashable {
    case compact, regular
}

extension EnvironmentValues {
    var horizontalSizeClass: UserInterfaceSizeClass? { .regular }
}

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
