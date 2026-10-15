# AppKit, SwiftTerm and themes

SwiftUI covers most of the UI, but the terminals, the message box, the switcher panel and the
keyboard work all drop into AppKit. This is where the platform bites.

## `acceptsFirstMouse` — the "UI doesn't work" bug

Symptom: open a chat, click into it, nothing happens — no cursor, no response — but toggle to the
terminal view and back and it works fine.

Cause: `NSResponder.acceptsFirstMouse(for:)` defaults to **false**. When the window isn't key, the
first click into a custom view only activates the window; the click itself is discarded. SwiftUI's
own controls opt in, so buttons appeared to work while our AppKit views didn't — which made it look
like a mysterious state bug rather than a click-routing one.

Every custom AppKit view here must override it:

```swift
override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
```

Done for `ComposeNSTextView` (the message box), `ClickableTerminalView` (every terminal — the
subclass exists purely for this) and `ClickThroughTextView` (the console). **Any new
`NSViewRepresentable` needs it too.**

## Vendored SwiftTerm

`Vendor/SwiftTerm` is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) at commit
`73b27f5`, trimmed to its sources so the build needs no network:

- Tests, the sample app, tools, docs and CI workflows are deleted.
- `Package.swift` is replaced with a minimal macOS-only manifest — the upstream one pulls
  swift-argument-parser, swift-docc-plugin and swift-png, which we don't need. `swifterm-terminfo`
  is kept; the build plugin reads it.
- **Local patch:** `TerminalView.terminal` was made `public internal(set)` in
  `Mac/MacTerminalView.swift`. Reading the live buffer is how a plain terminal's thumbnail is
  produced without a round trip (`TerminalView.visibleScreenText()` in `PlainTerminals.swift`).

If you ever re-vendor a newer SwiftTerm, re-apply that patch and re-trim the manifest.

Both terminal owners (`TerminalController` for tmux, `PlainTerminal` for local shells) keep their
`LocalProcessTerminalView` alive even when it isn't in the view hierarchy, so the process keeps
running and the buffer stays readable while the tile is hidden.

## The switcher panel

`TabSwitcherController` puts the ⌃⇥ HUD in its own `NSPanel`:

- `[.borderless, .nonactivatingPanel]`, `level = .floating`, clear background — it must **not**
  become key, or the main window loses focus and the ⌃⇥ menu shortcut stops firing.
- Stepping rides on the normal menu-command shortcuts (`App.swift`). Menu key equivalents are
  dispatched before the key window's `keyDown`, so they fire even while a terminal has focus.
- What a menu shortcut *can't* see is a modifier being **released**, so a local `NSEvent` monitor
  watches `.flagsChanged` for Control going up (commit), plus `.keyDown` for Esc/Return/arrows.
- The panel is sized from an estimate of its content (`contentHeight(forWidth:)`) and centred; it
  isn't resizable, so nothing needs to re-layout while thumbnails stream in.

## Local event monitors in use

`NSEvent.addLocalMonitorForEvents` appears three times; all of them must return the event unless
they deliberately consume it:

| Where | Watches | Does |
|---|---|---|
| `MacKeys.install()` | `.keyDown` | translates ⌘←/→, ⌥←/→, ⌥⌫, ⌘⌫ into readline keys for terminals |
| `LayoutModel.installClickMonitor()` | `.leftMouseDown` | focuses the tile under the pointer |
| `TabSwitcherController.installMonitors()` | `.flagsChanged`, `.keyDown` | drives the switcher HUD |

They're local (this app only) and installed once from `AppModel.start()`.

## Keyboard shortcuts

Declared as SwiftUI `Commands` in `App.swift`, which makes them real menu items — the reliable way
to get an app-wide shortcut that still fires while an AppKit view has first responder.

`⌘W` is ours: it closes the focused tile's window/pane/terminal (with confirmation) rather than the
OS "close window", which for a single-`Window` scene would quit the app.

**Confirmation dialogs need explicit key bindings.** SwiftUI's `.confirmationDialog` does not wire
Return/Escape on macOS, so every destructive dialog here spells it out: Cancel gets both
`.cancelAction` and `.defaultAction` (so a stray Return cancels safely), and the destructive button
gets `⌘Return`. Chaining two `.keyboardShortcut` modifiers on one button registers both.

## Themes

`ThemeManager` reads real VS Code themes rather than shipping its own:

- Discovers them in VS Code / VS Code Insiders / Cursor app bundles, `~/.vscode/extensions`,
  `~/.cursor/extensions` and the app's own import folder; resolves `%nls%` labels from
  `package.nls.json` and follows `include` chains.
- Parses **JSONC** — comments and trailing commas — because that's what VS Code writes
  (`ThemeManager.readJSONC`).
- "Match VS Code" polls `workbench.colorTheme` from VS Code's `settings.json` every few seconds.
- Maps `colors` onto `AppTheme` (surfaces, text, borders, accent, terminal background/foreground/
  cursor/selection, the 16 ANSI colours) and `tokenColors` onto a scope→colour lookup used by the
  code-block highlighter.
- Views read `\.theme` from the environment; terminals get `applyTerminalTheme(to:)` and re-apply on
  the `.themeChanged` notification.

Anything user-visible should take its colours from `AppTheme`, never from a hardcoded `Color`, or it
will look wrong under a dark VS Code theme.

### Terminals don't follow macOS on their own

SwiftTerm stores plain RGB, so a dynamic `NSColor` never re-resolves: a terminal keeps whatever
colours it was given when it was created. With the System theme those colours come from
`NSApp.effectiveAppearance`, so switching macOS between light and dark left every terminal behind —
and a dark-mode TUI like Codex, which draws white text, became unreadable on the light background.
`ThemeManager` therefore observes `NSApp.effectiveAppearance` (KVO) and re-applies, and terminals
re-read their colours on `.themeChanged`.

The same background is what answers a program's `OSC 11` query, which is how Codex and friends pick
a light or dark palette — one more reason it has to be right.

## Selecting text in the chat

A SwiftUI `Text` is **one selection unit**, and there is no selection that spans two views. So
rendering a message as a `VStack` of `Text` per paragraph — which is what it was — means you can
never drag across two paragraphs. That isn't a polish problem; it's the wrong shape, and copy
buttons don't substitute for it.

`MarkdownTextView` builds the whole message into one `NSAttributedString` and shows it in a single
`NSTextView`. Selection then behaves the way macOS text is supposed to: across paragraphs, code and
tables, ⌘A, ⌘C, double- and triple-click, shift-click to extend.

Notes for anyone touching it:

- **TextKit 1 on purpose.** `NSTextTable` renders the Markdown tables and needs the old layout
  manager, so the view is built with an explicit `NSTextStorage` / `NSLayoutManager` /
  `NSTextContainer` rather than letting `NSTextView` pick TextKit 2.
- **Height comes from `sizeThatFits`**, measured with `layoutManager.usedRect(for:)` at the width
  SwiftUI proposes. Get it wrong and messages clip or leave gaps.
- `AttributedString(markdown:)` marks runs with *inline presentation intents*, not fonts, so bold,
  italic and `code` have to be converted to real attributes by hand.
- Code blocks and table cells are `NSTextBlock` / `NSTextTableBlock`, which is where the padding,
  background and borders come from. Their dimensions are set per edge (`setWidth(_:type:for:edge:)`);
  the edgeless overload doesn't exist for padding or margin.
- ⌘C copies **plain text**: pasting a reply into a terminal or an issue shouldn't carry fonts.
- Anything interactive — the PR chips — can't live inside the text, so it stays a SwiftUI view
  underneath.

## Chat rendering cost

The chat re-renders on every transcript poll and on every tmux refresh (`ChatView` reads
`TmuxModel` from the environment), so anything done per render is done once a second for
every visible message. Things that keep scrolling smooth:

- `MarkdownText.init` is a **cache lookup** (`NSCache` keyed by the message text); the parse,
  including the PR links, runs once per distinct message. The heading regex is static — a
  `try! Regex(...)` inside a per-line loop compiled on every line of every message.
- `ChatStore.turns` is grouped in `items.didSet`, not in a computed property.
- `TurnView` is `Equatable` on its `Turn` and rendered with `.equatable()`, so turns that didn't
  change skip their body.
- `MessageCard` takes the "copy this turn" text as a closure; building it eagerly meant joining
  every tool result of every visible turn per render.
- `ChatStore.poll` only assigns `stale`/`missing`/`loaded` when the value changes — assigning a
  `@Published` the same value still fires `objectWillChange`.
- `PRPanelForChat` scans the transcript for PR mentions in `onChange(of: store.items)`, not in `body`.
- `ChatView` does **not** observe `TmuxModel`. The model publishes about once a second, and the
  chat owns the biggest layout in the app; the bits that need live state (`LiveActivity`,
  `HeaderBadge`, `SendingMessage`) are small child views with their own `@EnvironmentObject`.
- Claude's status line (`ActivityView`) sits **below** the scroll view, not at the end of the message
  stack. Its text changes every second while Claude works and its glyph runs a `phaseAnimator`; a
  child that changes size inside a plain `VStack` of hundreds of rows makes SwiftUI re-measure all
  of them (that showed up as `StackLayout.sizeThatFits` / `explicitAlignment` eating ~30% of the
  main thread in a `sample`).
- **Environment values must be `Equatable`.** `AppFont` and `AppTheme` are read by nearly every
  view; while `AppFont` wasn't Equatable, SwiftUI took it as changed on every `RootView` render
  (which happens whenever `AppModel`, the theme store or the plain-terminal store publish) and
  invalidated the whole window — that was the scroll lag after zoom went window-wide.

## Text size

macOS SwiftUI **ignores `dynamicTypeSize`** — `.font(.body)` renders identically at `.xSmall` and
`.accessibility3` (measured). So ⌘+/⌘−/⌘0 can't lean on it. `Zoom.swift` holds one base size and
`AppFont` derives every size from it; views read `\.fonts` from the environment instead of naming
`.body`/`.caption`. Terminals get `AppFont.terminal` and re-apply on `.fontSizeChanged`.

Zoom covers the **whole window**, not just the chat:

- `RootView` (and the Settings scene) set `.environment(\.fonts, zoom.font)` **and** `.font(zoom.font.body)`,
  so a `Text` with no style of its own follows the zoom too. Sidebar rows, buttons, badges, the
  status bar, files, diffs, PR cards, the tab switcher and the shortcuts sheet all scale.
- Never write `.font(.caption)` / `.font(.system(size: 11))`. Use `fonts.caption`, or `fonts.size(11)`
  for a one-off (it keeps the 13pt-relative ratio). The build has no `.font(.` left outside `Zoom.swift`.
- AppKit text views take an `NSFont` from `AppFont` (`nsBody` for the compose box, `nsMono` for the
  console) and compare it in `updateNSView`, which is how they pick up a change without a notification.
- Toolbar items are AppKit's and stay at the system size; `AnsiThumbnail` keeps its own 9pt because
  the thumbnail is scaled to fit anyway.
- The sidebar `List` sets its own row and header font, which beats the root `.font`. Rows and header
  icons there (`WindowRow`, `PlainTerminalRow`, section headers, the `•••`/`+` menu labels) name
  `fonts.body` explicitly, and icon slots use `fonts.points(18)` rather than a fixed width.
- A zoom step re-lays out every message, terminal and row, so `Zoom.set` **coalesces**: it records
  the wanted size at once but publishes `size` (and posts `.fontSizeChanged`) 120 ms after the last
  step. Holding ⌘+ does one rebuild, not one per key repeat. Read `pending` for "can zoom in/out".

If you add a view that uses `fonts.` it needs `@Environment(\.fonts) private var fonts` — in the
struct, not an extension (property wrappers can't live in extensions).
