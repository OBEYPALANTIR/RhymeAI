/// Words for pointing at things: a finger taps and swipes on iOS, a pointer
/// clicks and right-clicks on the Mac.
enum PlatformWording {
    #if os(macOS)
    static let tap = "Click"
    static let tapLowercase = "click"
    #else
    static let tap = "Tap"
    static let tapLowercase = "tap"
    #endif
}
