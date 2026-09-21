import AppKit
import SwiftUI

struct MacWindowSaveGuard: NSViewRepresentable {
    let editor: EditorViewModel
    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) { view.attach() }
    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) {
        if view.window?.delegate === coordinator { view.window?.delegate = coordinator.original }
    }
    final class AttachmentView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        func attach() {
            guard let window, let coordinator, window.delegate !== coordinator else { return }
            coordinator.original = window.delegate
            window.delegate = coordinator
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let editor: EditorViewModel
        weak var original: NSWindowDelegate?
        init(editor: EditorViewModel) { self.editor = editor }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard editor.saveCurrentProject() else { return false }
            editor.voiceMemoService.stopRecording()
            editor.voiceMemoService.stopPlayback()
            return original?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
