import AppKit

/// Turns a terminal screen dump (with ANSI colour escapes, from `tmux capture-pane -e`)
/// into a picture of that screen, so the switcher can show real thumbnails the way a
/// window manager shows window previews.
enum AnsiScreen {
    struct Run {
        var text: String
        var fg: NSColor?
        var bg: NSColor?
        var bold = false
        var dim = false
    }

    /// One parsed screen: its lines, each a list of coloured runs.
    struct Screen {
        var lines: [[Run]]
        var isEmpty: Bool { lines.allSatisfy { $0.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } } }
    }

    // MARK: Parsing

    /// Parses SGR escapes (colour, bold, dim, inverse, reset) and drops everything else.
    static func parse(_ text: String, maxLines: Int = 40, maxColumns: Int = 200) -> Screen {
        var lines: [[Run]] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines) {
            var runs: [Run] = []
            var current = Run(text: "")
            var fg: NSColor?, bg: NSColor?
            var bold = false, dim = false, inverse = false
            var columns = 0

            func flush() {
                if !current.text.isEmpty { runs.append(current) }
                current = Run(text: "", fg: inverse ? (bg ?? .black) : fg,
                              bg: inverse ? (fg ?? .white) : bg, bold: bold, dim: dim)
            }
            flush()

            var i = rawLine.startIndex
            while i < rawLine.endIndex, columns < maxColumns {
                let ch = rawLine[i]
                if ch == "\u{1b}", rawLine.index(after: i) < rawLine.endIndex, rawLine[rawLine.index(after: i)] == "[" {
                    // CSI … final byte
                    var j = rawLine.index(i, offsetBy: 2)
                    var params = ""
                    while j < rawLine.endIndex, !rawLine[j].isLetter {
                        params.append(rawLine[j])
                        j = rawLine.index(after: j)
                    }
                    if j < rawLine.endIndex, rawLine[j] == "m" {
                        applySGR(params, fg: &fg, bg: &bg, bold: &bold, dim: &dim, inverse: &inverse)
                        flush()
                    }
                    i = j < rawLine.endIndex ? rawLine.index(after: j) : rawLine.endIndex
                    continue
                }
                if ch == "\u{1b}" {  // some other escape: skip its final byte
                    i = rawLine.index(after: i)
                    continue
                }
                current.text.append(ch)
                columns += 1
                i = rawLine.index(after: i)
            }
            if !current.text.isEmpty { runs.append(current) }
            lines.append(runs)
        }
        return Screen(lines: lines)
    }

    private static func applySGR(_ params: String, fg: inout NSColor?, bg: inout NSColor?,
                                 bold: inout Bool, dim: inout Bool, inverse: inout Bool) {
        let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var k = 0
        while k < codes.count {
            let code = codes[k]
            switch code {
            case 0: fg = nil; bg = nil; bold = false; dim = false; inverse = false
            case 1: bold = true
            case 2: dim = true
            case 7: inverse = true
            case 22: bold = false; dim = false
            case 27: inverse = false
            case 30...37: fg = palette(code - 30)
            case 39: fg = nil
            case 40...47: bg = palette(code - 40)
            case 49: bg = nil
            case 90...97: fg = palette(code - 90 + 8)
            case 100...107: bg = palette(code - 100 + 8)
            case 38, 48:
                // 38;5;N (256 colour) or 38;2;R;G;B (true colour)
                guard k + 1 < codes.count else { k = codes.count; break }
                let isFg = code == 38
                if codes[k + 1] == 5, k + 2 < codes.count {
                    let c = palette(codes[k + 2])
                    if isFg { fg = c } else { bg = c }
                    k += 2
                } else if codes[k + 1] == 2, k + 4 < codes.count {
                    let c = NSColor(srgbRed: CGFloat(codes[k + 2]) / 255, green: CGFloat(codes[k + 3]) / 255,
                                    blue: CGFloat(codes[k + 4]) / 255, alpha: 1)
                    if isFg { fg = c } else { bg = c }
                    k += 4
                }
            default: break
            }
            k += 1
        }
    }

    /// The xterm 256-colour palette.
    static func palette(_ index: Int) -> NSColor {
        switch index {
        case 0..<16:
            let base: [(Int, Int, Int)] = [
                (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
                (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
                (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
                (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
            ]
            let (r, g, b) = base[index]
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case 16..<232:
            let i = index - 16
            let steps = [0, 95, 135, 175, 215, 255].map { CGFloat($0) / 255 }
            return NSColor(srgbRed: steps[(i / 36) % 6], green: steps[(i / 6) % 6], blue: steps[i % 6], alpha: 1)
        case 232..<256:
            let v = CGFloat(8 + (index - 232) * 10) / 255
            return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        default:
            return .white
        }
    }

    // MARK: Drawing

    /// Draws the screen as an image: monospaced cells, real colours, on the terminal's
    /// own background — a miniature of what that window actually looks like.
    static func image(_ screen: Screen, background: NSColor, foreground: NSColor, fontSize: CGFloat = 9) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let cellWidth = ("W" as NSString).size(withAttributes: [.font: font]).width
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let columns = max(screen.lines.map { line in line.reduce(0) { $0 + $1.text.count } }.max() ?? 80, 40)
        let size = NSSize(width: max(cellWidth * CGFloat(columns), 200),
                          height: max(lineHeight * CGFloat(screen.lines.count), 40))

        return NSImage(size: size, flipped: true) { _ in
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            var y: CGFloat = 0
            for line in screen.lines {
                var x: CGFloat = 0
                for run in line {
                    let width = cellWidth * CGFloat(run.text.count)
                    if let bg = run.bg {
                        bg.setFill()
                        NSRect(x: x, y: y, width: width, height: lineHeight).fill()
                    }
                    var color = run.fg ?? foreground
                    if run.dim { color = color.withAlphaComponent(0.55) }
                    (run.text as NSString).draw(
                        at: NSPoint(x: x, y: y),
                        withAttributes: [.font: run.bold ? boldFont : font, .foregroundColor: color])
                    x += width
                }
                y += lineHeight
            }
            return true
        }
    }
}
