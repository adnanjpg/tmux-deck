import AppKit
import SwiftUI

/// A whole message as one piece of selectable text.
///
/// Rendering each paragraph as its own SwiftUI `Text` means each one is its own selection: you
/// can't drag across two of them, because SwiftUI has no notion of a selection spanning views.
/// So the message is built into a single `NSAttributedString` and shown in one `NSTextView` —
/// which gives the real thing: drag across paragraphs, code and tables, ⌘A, ⌘C, double-click a
/// word, triple-click a paragraph, shift-click to extend.
///
/// TextKit 1 on purpose: `NSTextTable` is what renders Markdown tables, and it needs the old
/// layout manager.
struct MarkdownTextView: NSViewRepresentable {
    let blocks: [MarkdownText.Block]
    let theme: AppTheme
    let fonts: AppFont

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SelectableTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let view = SelectableTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [NSView.AutoresizingMask.width]
        view.textContainerInset = .zero
        view.delegate = context.coordinator
        view.linkTextAttributes = [:]
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: SelectableTextView, context: Context) {
        apply(to: view, coordinator: context.coordinator)
    }

    /// SwiftUI asks how tall this is for the width it has; measuring the laid-out text is the
    /// only way to answer, and getting it wrong shows up as a clipped or over-tall message.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableTextView, context: Context) -> CGSize? {
        var width = proposal.width ?? nsView.bounds.width
        if width <= 0 || !width.isFinite { width = nsView.lastWidth }
        guard width > 0, width.isFinite,
              let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        nsView.lastWidth = width
        if abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height
        return CGSize(width: width, height: ceil(height))
    }

    /// Rebuilds the text only when something it depends on actually changed.
    ///
    /// Comparing the built strings doesn't work: every build makes fresh `NSTextBlock` objects,
    /// so `isEqual` is always false, and re-setting the storage on every SwiftUI update
    /// invalidates layout, which makes SwiftUI measure again — a message that never settles and
    /// draws as nothing.
    private func apply(to view: SelectableTextView, coordinator: Coordinator) {
        let key = Key(blocks: blocks, theme: theme.name, isDark: theme.isDark, size: fonts.base)
        if coordinator.key != key {
            coordinator.key = key
            let built = MarkdownAttributed.build(blocks, theme: theme, fonts: fonts)
            view.textStorage?.setAttributedString(built)
            view.plainText = built.string
            view.invalidateIntrinsicContentSize()
        }
        view.selectedTextAttributes = [
            .backgroundColor: theme.terminalSelection ?? .selectedTextBackgroundColor,
        ]
    }

    struct Key: Equatable {
        var blocks: [MarkdownText.Block]
        var theme: String
        var isDark: Bool?
        var size: CGFloat
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var key: Key?

        func textView(_ view: NSTextView, clickedOnLink link: Any, at index: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

/// The text view itself: first-mouse so one click selects, and a copy that yields plain text.
final class SelectableTextView: NSTextView {
    var plainText = ""
    /// The last width it was measured at, so a measurement with no proposal still has one.
    var lastWidth: CGFloat = 600

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ⌘C on a selection copies exactly what's selected, as plain text — pasting a message into
    /// a terminal or an issue shouldn't bring fonts and colours with it.
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        let text = range.length > 0
            ? (string as NSString).substring(with: range)
            : plainText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let hasSelection = selectedRange().length > 0
        let copy = NSMenuItem(title: hasSelection ? "Copy" : "Copy message",
                              action: #selector(copy(_:)), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)
        let all = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        all.target = self
        menu.addItem(all)
        return menu
    }
}

/// Turns the parsed Markdown blocks into one attributed string.
enum MarkdownAttributed {
    static func build(_ blocks: [MarkdownText.Block], theme: AppTheme, fonts: AppFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = theme.foreground ?? .labelColor

        for (i, block) in blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            switch block {
            case .text(let s):
                out.append(paragraph(s, font: NSFont.systemFont(ofSize: fonts.points(13)),
                                     color: body, theme: theme, fonts: fonts))
            case .heading(let s, let level):
                let size = fonts.points(level <= 2 ? 15 : 13)
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = 6
                style.paragraphSpacing = 2
                let text = paragraph(s, font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                     color: body, theme: theme, fonts: fonts)
                let heading = NSMutableAttributedString(attributedString: text)
                heading.addAttribute(.paragraphStyle, value: style,
                                     range: NSRange(location: 0, length: heading.length))
                out.append(heading)
            case .code(let s):
                out.append(codeBlock(s, theme: theme, fonts: fonts))
            case .table(let header, let alignments, let rows):
                out.append(table(header: header, alignments: alignments, rows: rows,
                                 theme: theme, fonts: fonts))
            }
        }
        return out
    }

    /// One paragraph, with the inline Markdown (bold, italic, `code`, links) applied.
    private static func paragraph(_ source: String, font: NSFont, color: NSColor,
                                  theme: AppTheme, fonts: AppFont) -> NSAttributedString {
        let attributed = (try? AttributedString(markdown: source,
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        let out = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let whole = NSRange(location: 0, length: out.length)

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 4
        out.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: style], range: whole)

        // AttributedString(markdown:) marks its runs with inline presentation intents rather than
        // fonts, so bold, italic and `code` have to be turned into real attributes here.
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent,
                  let range = NSRange(run.range, in: attributed) as NSRange?,
                  range.location + range.length <= out.length else { continue }
            var traits: NSFontTraitMask = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            if intent.contains(.code) {
                out.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.94,
                                                                      weight: .regular),
                                   .backgroundColor: theme.codeBackground.withAlphaComponent(0.6)],
                                  range: range)
            } else if !traits.isEmpty {
                let styled = NSFontManager.shared.convert(font, toHaveTrait: traits)
                out.addAttribute(.font, value: styled, range: range)
            }
        }
        for run in attributed.runs {
            guard let link = run.link, let range = NSRange(run.range, in: attributed) as NSRange?,
                  range.location + range.length <= out.length else { continue }
            out.addAttributes([.link: link,
                               .foregroundColor: theme.link ?? theme.accent,
                               .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        return out
    }

    /// A fenced code block, in a text block so it gets the padded, tinted box.
    private static func codeBlock(_ source: String, theme: AppTheme, fonts: AppFont) -> NSAttributedString {
        let block = NSTextBlock()
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            block.setWidth(10, type: .absoluteValueType, for: .padding, edge: edge)
            block.setWidth(4, type: .absoluteValueType, for: .margin, edge: edge)
        }
        block.backgroundColor = theme.codeBackground
        block.setBorderColor(theme.border)
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: edge)
        }

        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.lineSpacing = 2

        let colored = NSMutableAttributedString(
            attributedString: NSAttributedString(SyntaxHighlighter.highlight(source, theme: theme)))
        let whole = NSRange(location: 0, length: colored.length)
        colored.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: fonts.points(12), weight: .regular),
                               .paragraphStyle: style], range: whole)
        if colored.length == 0 { return colored }
        return colored
    }

    /// A Markdown table as a real `NSTextTable`, so the columns line up and the whole thing is
    /// part of the same selectable text.
    private static func table(header: [String], alignments: [MarkdownText.TableAlignment],
                              rows: [[String]], theme: AppTheme, fonts: AppFont) -> NSAttributedString {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return NSAttributedString(string: "") }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let out = NSMutableAttributedString()
        let all = [header] + rows
        for (r, row) in all.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                            startingColumn: c, columnSpan: 1)
                cell.setBorderColor(theme.border)
                for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
                    cell.setWidth(1, type: .absoluteValueType, for: .border, edge: edge)
                    cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: edge)
                }
                if r == 0 { cell.backgroundColor = theme.codeBackground }

                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                switch alignments.indices.contains(c) ? alignments[c] : .leading {
                case .leading: style.alignment = .left
                case .center: style.alignment = .center
                case .trailing: style.alignment = .right
                }

                let text = c < row.count ? row[c] : ""
                let font = NSFont.systemFont(ofSize: fonts.points(12), weight: r == 0 ? .semibold : .regular)
                let piece = NSMutableAttributedString(
                    attributedString: paragraph(text, font: font,
                                                color: theme.foreground ?? .labelColor,
                                                theme: theme, fonts: fonts))
                piece.addAttribute(.paragraphStyle, value: style,
                                   range: NSRange(location: 0, length: piece.length))
                piece.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
                out.append(piece)
            }
        }
        return out
    }
}
