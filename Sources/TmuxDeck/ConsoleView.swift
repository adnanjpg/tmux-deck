import AppKit
import SwiftUI

/// A plain terminal window shown as a normal Mac text view: select, copy and
/// search output like any document, and type commands in the box underneath.
struct ConsoleView: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    @EnvironmentObject private var model: TmuxModel
    let window: TmuxWindow
    @State private var output = ""

    var body: some View {
        VStack(spacing: 0) {
            OutputTextView(text: output, theme: theme, font: fonts.nsMono)
            Divider()
            ComposeBar(window: window)
                .id(window.id)
        }
        .task(id: window.id) {
            let target = sq(window.paneID.isEmpty ? window.windowTarget : window.paneID)
            while !Task.isCancelled {
                let result = await model.remote.run("tmux capture-pane -p -J -S -3000 -t \(target)")
                if result.ok {
                    let text = result.stdout.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                    if text != output { output = text }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct OutputTextView: NSViewRepresentable {
    let text: String
    let theme: AppTheme
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = ClickThroughTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 16, height: 14)
        tv.backgroundColor = .textBackgroundColor
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.font != font { tv.font = font }
        tv.backgroundColor = theme.terminalBackground ?? theme.background
        tv.textColor = theme.terminalForeground ?? theme.foreground ?? .textColor
        guard tv.string != text else { return }
        let clip = scroll.contentView
        let atBottom = clip.bounds.maxY >= tv.frame.height - 40
        let selection = tv.selectedRanges
        tv.string = text
        if selection.allSatisfy({ ($0 as! NSRange).upperBound <= (text as NSString).length }) {
            tv.selectedRanges = selection
        }
        if atBottom { tv.scrollToEndOfDocument(nil) }
    }
}
