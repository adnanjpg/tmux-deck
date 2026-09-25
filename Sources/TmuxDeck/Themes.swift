import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: The theme the views use

/// Colors the app paints with. `.system` is plain macOS; a VS Code theme fills in the rest.
struct AppTheme {
    var name: String
    var isDark: Bool?                 // nil: follow macOS
    var background: NSColor
    var foreground: NSColor?          // nil: system label color
    var secondary: NSColor?
    var sidebar: NSColor?             // nil: keep the translucent sidebar
    var border: NSColor
    var accent: NSColor
    var codeBackground: NSColor
    var inputBackground: NSColor
    var panelBackground: NSColor
    var widgetBackground: NSColor
    var link: NSColor?
    var terminalBackground: NSColor?
    var terminalForeground: NSColor?
    var terminalCursor: NSColor?
    var terminalSelection: NSColor?
    var ansi: [NSColor]?              // 16 colors
    var tokens: [TokenRule] = []

    var bg: Color { Color(nsColor: background) }
    var fg: Color? { foreground.map { Color(nsColor: $0) } }
    var line: Color { Color(nsColor: border) }
    var tint: Color { Color(nsColor: accent) }
    var code: Color { Color(nsColor: codeBackground) }
    var input: Color { Color(nsColor: inputBackground) }
    var panel: Color { Color(nsColor: panelBackground) }
    var widget: Color { Color(nsColor: widgetBackground) }

    static let system = AppTheme(
        name: "System", isDark: nil,
        background: .textBackgroundColor, foreground: nil, secondary: nil, sidebar: nil,
        border: .separatorColor, accent: .controlAccentColor, codeBackground: .controlBackgroundColor,
        inputBackground: .textBackgroundColor, panelBackground: .windowBackgroundColor,
        widgetBackground: NSColor.secondaryLabelColor.withAlphaComponent(0.06), link: nil,
        terminalBackground: nil, terminalForeground: nil, terminalCursor: nil, terminalSelection: nil, ansi: nil)

    /// The color for a syntax scope ("keyword", "string", "comment"…): the most specific matching rule.
    func tokenColor(_ scope: String) -> NSColor? {
        var best: (len: Int, color: NSColor)?
        for rule in tokens {
            guard let color = rule.foreground else { continue }
            for s in rule.scopes {
                let match = s == scope || scope.hasPrefix(s + ".") || s.hasPrefix(scope + ".")
                if match, best == nil || s.count > best!.len { best = (s.count, color) }
            }
        }
        return best?.color
    }
}

struct TokenRule {
    var scopes: [String]
    var foreground: NSColor?
    var italic = false
    var bold = false
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.system
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: VS Code themes

/// A theme contributed by VS Code, Cursor, an installed extension, or an imported file.
struct VSCodeThemeRef: Identifiable, Hashable {
    var label: String
    var uiTheme: String     // vs, vs-dark, hc-black, hc-light
    var path: URL
    var source: String
    var id: String { path.path }
    var isDark: Bool { uiTheme == "vs-dark" || uiTheme == "hc-black" }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var available: [VSCodeThemeRef] = []
    @Published private(set) var theme: AppTheme = .system
    /// "system", "vscode" (match VS Code's current theme), or a theme file path.
    @Published private(set) var selection: String
    @Published private(set) var vscodeCurrent: String?
    private var watchTask: Task<Void, Never>?

    static let importDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TmuxDeck/Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        selection = UserDefaults.standard.string(forKey: "theme.selection") ?? "system"
        scan()
        apply()
        startWatchingVSCode()
    }

    func select(_ value: String) {
        selection = value
        UserDefaults.standard.set(value, forKey: "theme.selection")
        apply()
    }

    private func apply() {
        let ref: VSCodeThemeRef?
        switch selection {
        case "system": ref = nil
        case "vscode":
            vscodeCurrent = Self.vscodeColorTheme()
            ref = vscodeCurrent.flatMap { name in available.first { $0.label == name } }
        default: ref = available.first { $0.id == selection }
        }
        theme = ref.flatMap(Self.load) ?? .system
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }

    /// Follows VS Code's theme when "Match VS Code" is chosen.
    private func startWatchingVSCode() {
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.selection == "vscode" else { continue }
                let now = Self.vscodeColorTheme()
                if now != self.vscodeCurrent { self.apply() }
            }
        }
    }

    // MARK: Finding themes

    func scan() {
        var found: [VSCodeThemeRef] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let builtIn: [(String, String)] = [
            ("/Applications/Visual Studio Code.app/Contents/Resources/app/extensions", "VS Code"),
            ("/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/extensions", "VS Code Insiders"),
            ("/Applications/Cursor.app/Contents/Resources/app/extensions", "Cursor"),
            (home.appendingPathComponent(".vscode/extensions").path, "Extension"),
            (home.appendingPathComponent(".cursor/extensions").path, "Extension"),
            (Self.importDir.path, "Imported"),
        ]
        for (dir, source) in builtIn {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries.sorted() {
                let ext = URL(fileURLWithPath: dir).appendingPathComponent(entry)
                found += Self.themes(inExtension: ext, source: source)
            }
        }
        // Several versions of one extension list the same themes: keep the newest (last sorted).
        var byKey: [String: VSCodeThemeRef] = [:]
        for t in found { byKey["\(t.source)|\(t.label)"] = t }
        available = byKey.values.sorted { ($0.isDark ? 1 : 0, $0.label) < ($1.isDark ? 1 : 0, $1.label) }
    }

    private static func themes(inExtension dir: URL, source: String) -> [VSCodeThemeRef] {
        let pkgURL = dir.appendingPathComponent("package.json")
        guard let pkg = readJSONC(pkgURL) as? [String: Any],
              let contributes = pkg["contributes"] as? [String: Any],
              let list = contributes["themes"] as? [[String: Any]] else { return [] }
        let nls = readJSONC(dir.appendingPathComponent("package.nls.json")) as? [String: Any] ?? [:]
        let extName = (pkg["displayName"] as? String).map { localized($0, nls) } ?? dir.lastPathComponent
        return list.compactMap { t in
            guard let path = t["path"] as? String else { return nil }
            let url = dir.appendingPathComponent(path).standardizedFileURL
            guard url.pathExtension.lowercased() == "json" else { return nil }   // .tmTheme isn't supported
            let label = localized(t["label"] as? String ?? t["id"] as? String ?? url.lastPathComponent, nls)
            return VSCodeThemeRef(label: label, uiTheme: t["uiTheme"] as? String ?? "vs-dark", path: url,
                                  source: source == "Extension" || source == "Imported" ? extName : source)
        }
    }

    /// "%darkPlusColorThemeLabel%" → "Dark+" using the extension's package.nls.json.
    private static func localized(_ s: String, _ nls: [String: Any]) -> String {
        guard s.hasPrefix("%"), s.hasSuffix("%") else { return s }
        let key = String(s.dropFirst().dropLast())
        if let v = nls[key] as? String { return v }
        if let v = (nls[key] as? [String: Any])?["message"] as? String { return v }
        return key
    }

    /// The theme VS Code is using now, from its settings.json.
    static func vscodeColorTheme() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/settings.json")
        return (readJSONC(url) as? [String: Any])?["workbench.colorTheme"] as? String ?? "Dark Modern"
    }

    // MARK: Importing

    /// Imports a theme .json, or a .vsix extension (unzipped), into the app's theme folder.
    func importTheme(from url: URL) -> String? {
        let fm = FileManager.default
        let name = url.deletingPathExtension().lastPathComponent
        let dest = Self.importDir.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: dest)
        do {
            if url.pathExtension.lowercased() == "vsix" {
                let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                p.arguments = ["-q", url.path, "-d", tmp.path]
                try p.run(); p.waitUntilExit()
                try fm.moveItem(at: tmp.appendingPathComponent("extension"), to: dest)
            } else {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: dest.appendingPathComponent("theme.json"))
                let json = Self.readJSONC(url) as? [String: Any]
                let label = json?["name"] as? String ?? name
                let dark = (json?["type"] as? String).map { $0 != "light" } ?? true
                let pkg: [String: Any] = ["displayName": label, "contributes": ["themes": [
                    ["label": label, "uiTheme": dark ? "vs-dark" : "vs", "path": "./theme.json"]]]]
                try JSONSerialization.data(withJSONObject: pkg).write(to: dest.appendingPathComponent("package.json"))
            }
        } catch {
            return "Couldn't import: \(error.localizedDescription)"
        }
        scan()
        if let first = available.first(where: { $0.path.path.hasPrefix(dest.path) }) { select(first.id) }
        return nil
    }

    // MARK: Loading a theme

    static func load(_ ref: VSCodeThemeRef) -> AppTheme? {
        var colors: [String: String] = [:]
        var tokenRules: [[String: Any]] = []
        var type: String?
        func read(_ url: URL, depth: Int) {
            guard depth < 6, let json = readJSONC(url) as? [String: Any] else { return }
            if let include = json["include"] as? String {
                read(url.deletingLastPathComponent().appendingPathComponent(include).standardizedFileURL, depth: depth + 1)
            }
            for (k, v) in json["colors"] as? [String: Any] ?? [:] { if let s = v as? String { colors[k] = s } }
            if let rules = json["tokenColors"] as? [[String: Any]] { tokenRules += rules }
            if let t = json["type"] as? String { type = t }
        }
        read(ref.path, depth: 0)
        guard !colors.isEmpty || !tokenRules.isEmpty else { return nil }

        let dark = type.map { $0 != "light" && $0 != "hcLight" } ?? ref.isDark
        func c(_ keys: String...) -> NSColor? {
            for k in keys { if let s = colors[k], let color = NSColor(hex: s) { return color } }
            return nil
        }
        let bg = c("editor.background") ?? (dark ? NSColor(white: 0.12, alpha: 1) : .white)
        let fg = c("editor.foreground", "foreground") ?? (dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.12, alpha: 1))
        let accent = c("focusBorder", "button.background", "textLink.foreground") ?? .controlAccentColor
        let border = c("panel.border", "editorGroup.border", "sideBar.border", "contrastBorder", "widget.border")
            ?? fg.withAlphaComponent(0.15)

        var theme = AppTheme(
            name: ref.label, isDark: dark,
            background: bg, foreground: fg,
            secondary: c("descriptionForeground") ?? fg.withAlphaComponent(0.65),
            sidebar: c("sideBar.background") ?? bg,
            border: border, accent: accent,
            codeBackground: c("textCodeBlock.background", "editorWidget.background", "input.background") ?? fg.withAlphaComponent(0.06),
            inputBackground: c("input.background") ?? bg,
            panelBackground: c("panel.background", "editorGroupHeader.tabsBackground", "sideBar.background") ?? bg,
            widgetBackground: c("editorWidget.background", "sideBarSectionHeader.background") ?? fg.withAlphaComponent(0.05),
            link: c("textLink.foreground"),
            terminalBackground: c("terminal.background", "panel.background") ?? bg,
            terminalForeground: c("terminal.foreground") ?? fg,
            terminalCursor: c("terminalCursor.foreground", "editorCursor.foreground"),
            terminalSelection: c("terminal.selectionBackground", "editor.selectionBackground"),
            ansi: nil)

        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let ansi = (names.map { "terminal.ansi\($0)" } + names.map { "terminal.ansiBright\($0)" }).map { colors[$0].flatMap(NSColor.init(hex:)) }
        if ansi.allSatisfy({ $0 != nil }) { theme.ansi = ansi.compactMap { $0 } }

        theme.tokens = tokenRules.compactMap { rule in
            let settings = rule["settings"] as? [String: Any] ?? [:]
            let scopes: [String]
            if let s = rule["scope"] as? String { scopes = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            else if let a = rule["scope"] as? [String] { scopes = a }
            else { return nil }
            let style = settings["fontStyle"] as? String ?? ""
            return TokenRule(scopes: scopes, foreground: (settings["foreground"] as? String).flatMap(NSColor.init(hex:)),
                             italic: style.contains("italic"), bold: style.contains("bold"))
        }
        return theme
    }

    /// JSON with comments and trailing commas, as VS Code writes it.
    static func readJSONC(_ url: URL) -> Any? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out = "", inString = false, escape = false
        var chars = Array(text)[...]
        while let ch = chars.popFirst() {
            if inString {
                out.append(ch)
                if escape { escape = false } else if ch == "\\" { escape = true } else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true; out.append(ch); continue }
            if ch == "/", chars.first == "/" { while let n = chars.first, n != "\n" { chars.removeFirst() }; continue }
            if ch == "/", chars.first == "*" {
                chars.removeFirst()
                while let n = chars.popFirst() { if n == "*", chars.first == "/" { chars.removeFirst(); break } }
                continue
            }
            out.append(ch)
        }
        let cleaned = out.replacingOccurrences(of: #",(\s*[\]}])"#, with: "$1", options: .regularExpression)
        return try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))
    }
}

extension Notification.Name {
    static let themeChanged = Notification.Name("TmuxDeckThemeChanged")
}

extension NSColor {
    /// #RGB, #RGBA, #RRGGBB or #RRGGBBAA.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let a = s.count == 8 ? CGFloat(v & 0xff) / 255 : 1
        let rgb = s.count == 8 ? v >> 8 : v
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: a)
    }
}

// MARK: Syntax highlighting for code blocks

enum SyntaxHighlighter {
    private static let keywords: Set<String> = [
        "func", "let", "var", "const", "if", "else", "for", "while", "return", "class", "struct", "enum",
        "import", "from", "def", "public", "private", "protected", "internal", "static", "async", "await",
        "try", "catch", "throw", "throws", "new", "in", "of", "switch", "case", "break", "continue", "default",
        "interface", "type", "extends", "implements", "using", "namespace", "fn", "pub", "mut", "impl", "match",
        "do", "done", "then", "fi", "elif", "export", "package", "function", "lambda", "with", "as", "is",
        "not", "and", "or", "yield", "readonly", "override", "virtual", "abstract", "sealed", "void", "select",
        "where", "guard", "defer", "some", "any", "self", "this", "super", "echo", "local", "set", "unset",
    ]
    private static let constants: Set<String> = ["true", "false", "nil", "null", "None", "True", "False", "undefined"]

    private static let pattern = try! NSRegularExpression(pattern: [
        #"(?<comment>//[^\n]*|#(?![!\[])[^\n]*|/\*[\s\S]*?\*/|--[^\n]*)"#,
        #"(?<string>"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`)"#,
        #"(?<number>\b\d+(?:\.\d+)?\b)"#,
        #"(?<word>[A-Za-z_][A-Za-z0-9_]*)(?<call>\s*\()?"#,
    ].joined(separator: "|"))

    /// Colors code with the theme's token colors (or a neutral palette for the system theme).
    static func highlight(_ code: String, theme: AppTheme) -> AttributedString {
        var out = AttributedString(code)
        let ns = code as NSString
        func color(_ scope: String, _ fallback: NSColor) -> Color {
            Color(nsColor: theme.tokenColor(scope) ?? fallback)
        }
        let comment = color("comment", .systemGray)
        let string = color("string", .systemRed)
        let number = color("constant.numeric", .systemPurple)
        let keyword = color("keyword", .systemPink)
        let constant = color("constant.language", .systemPurple)
        let function = color("entity.name.function", .systemTeal)
        let type = color("entity.name.type", .systemTeal)
        for m in pattern.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            func paint(_ group: String, _ c: Color) {
                let r = m.range(withName: group)
                guard r.location != NSNotFound, let range = Range(r, in: code),
                      let ar = Range(range, in: out) else { return }
                out[ar].foregroundColor = c
            }
            if m.range(withName: "comment").location != NSNotFound { paint("comment", comment); continue }
            if m.range(withName: "string").location != NSNotFound { paint("string", string); continue }
            if m.range(withName: "number").location != NSNotFound { paint("number", number); continue }
            let wr = m.range(withName: "word")
            guard wr.location != NSNotFound else { continue }
            let word = ns.substring(with: wr)
            if keywords.contains(word) { paint("word", keyword) }
            else if constants.contains(word) { paint("word", constant) }
            else if m.range(withName: "call").location != NSNotFound { paint("word", function) }
            else if word.first?.isUppercase == true, word.count > 1 { paint("word", type) }
        }
        return out
    }
}
