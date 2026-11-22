#if DEBUG && os(macOS)
import AppKit

/// TEMPORARY diagnostic, to be removed before the PR leaves draft. Appends a line to
/// Library/Caches/focus-trace.log in the app's container for each left mouse up and key
/// down in the main window, and whenever that window's minimum size changes. Passive: the
/// event monitor hands every event on unchanged. A key is recorded only as delete, arrow
/// or other; never characters, text, titles or lyrics.
@MainActor
enum FocusTrace {
    private static var monitor: Any?
    private static var observer: NSObjectProtocol?
    private static var lastMinSize: NSSize?
    static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("focus-trace.log")

    static func start() {
        guard monitor == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        write("start")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { event in
            MainActor.assumeIsolated {
                if let window = event.window, window === NSApp.mainWindow {
                    write((event.type == .keyDown ? "keyDown " + key(event.keyCode) : "mouseUp") + " " + describe(window))
                }
            }
            return event
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window === NSApp.mainWindow,
                      window.contentMinSize != lastMinSize else { return }
                lastMinSize = window.contentMinSize
                write("minSize " + describe(window))
            }
        }
    }

    private static func key(_ code: UInt16) -> String {
        switch code {
        case 51, 117: "delete"
        case 123...126: "arrow"
        default: "other"
        }
    }

    private static func describe(_ window: NSWindow) -> String {
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "responder=\(responder) frame=\(Int(window.frame.width))x\(Int(window.frame.height)) contentMin=\(Int(window.contentMinSize.width))x\(Int(window.contentMinSize.height))"
    }

    private static func write(_ line: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
