import AppKit
import SwiftTerm

/// Makes text-editor shortcuts work when you type directly in a terminal pane.
/// Shells and Claude Code understand the classic readline keys, so each Mac
/// shortcut is translated to its readline equivalent before the terminal sees it.
enum MacKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let term = event.window?.firstResponder as? LocalProcessTerminalView,
                  let bytes = translate(event) else { return event }
            term.send(data: bytes[...])
            return nil
        }
    }

    private static func translate(_ event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let esc: UInt8 = 0x1b
        switch (flags, event.keyCode) {
        case (.command, 123): return [0x01]            // ⌘← start of line   (Ctrl+A)
        case (.command, 124): return [0x05]            // ⌘→ end of line     (Ctrl+E)
        case (.option, 123): return [esc, 0x62]        // ⌥← word left       (Esc b)
        case (.option, 124): return [esc, 0x66]        // ⌥→ word right      (Esc f)
        case (.option, 51): return [0x17]              // ⌥⌫ delete word     (Ctrl+W)
        case (.command, 51): return [0x15]             // ⌘⌫ delete line     (Ctrl+U)
        case (.option, 117): return [esc, 0x64]        // ⌥⌦ delete next word (Esc d)
        case (.command, 117): return [0x0b]            // ⌘⌦ delete to end   (Ctrl+K)
        case (.shift, 36): return [esc, 0x0d]          // ⇧↩ new line in Claude (Esc Enter)
        default: return nil
        }
    }
}
