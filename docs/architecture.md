# Architecture

One window, one process. Everything you see is SwiftUI inside that window; the "windows" you switch
between are tmux windows on some machine, or plain shells this app spawned.

## The shape of it

```
TmuxDeckApp (App.swift)
└── RootView                         theme + update banner wrapper
    └── ContentView                  sidebar | detail, toolbar, every dialog
        ├── sidebar                  servers → sessions → windows → panes, plain terminals
        └── SplitLayoutView          the tiled detail area (SplitLayout.swift)
            └── tileContent(tag)     picks ONE of:
                ├── ChatView         a Claude window (reads its transcript)
                ├── TerminalPane     raw tmux terminal (SwiftTerm over SSH)
                ├── ConsoleView      non-Claude tmux window as selectable text
                └── PlainTerminalView a local shell/Claude with no tmux
```

Singletons (all `@MainActor`, all `ObservableObject`):

| Singleton | Lives in | Owns |
|---|---|---|
| `AppModel.shared` | AppModel.swift | the list of servers, port forwarders, grouped tab list |
| `LayoutModel.shared` | SplitLayout.swift | the split tree, which tile is focused, ⌘W close requests |
| `PlainTerminalStore.shared` | PlainTerminals.swift | non-tmux terminals on this Mac |
| `ThemeManager.shared` | Themes.swift | the current theme, VS Code theme discovery |
| `TabSwitcherController.shared` | TabSwitcher.swift | the ⌃⇥ HUD panel and its thumbnails |
| `PRStore.shared` | PullRequests.swift | GitHub PR data via `gh` |
| `UpdateWatcher.shared` | UpdateWatcher.swift | "a newer build is installed" banner |

One `TmuxModel` exists per server (not a singleton). `AppModel.shared.servers` holds them.

## Tags: how a tile knows what to show

A **tag** is the id of anything that can fill a tile. Two shapes:

```
<ssh host>#<session>|<window id>              a tmux window   e.g.  tailscale110#a|@30
<ssh host>#<session>|<window id>|<pane id>    a tmux pane     e.g.  tailscale110#a|@30|%31
plain#<uuid>                                  a plain terminal on this Mac
```

The host part is the *ssh host* (`Remote.host`), not the display name — `local` is the special host
meaning this Mac. `TileResolver.resolve(tag)` turns a tmux tag back into `(TmuxModel, TmuxWindow)`;
`PlainTerminalStore.shared.terminal(forTag:)` resolves a `plain#` tag.

Tags are used as: sidebar `List` selection values, drag-and-drop payloads, layout-tree leaf
contents, and switcher entries. Keep them stable — the layout tree is persisted with them.

## Split layout

`LayoutNode` is a binary tree, `Codable`, persisted in `UserDefaults` under `layout`:

```swift
indirect enum LayoutNode {
    case leaf(id: String, tag: String?)                       // one tile; nil tag = empty
    case split(id: String, axis:, first:, second:, ratio:)    // two children + divider position
}
```

`SplitLayoutView` walks the tree each layout pass, computing a frame per leaf plus the divider
rects, and positions tiles absolutely in a `ZStack`. Leaf **ids stay stable** across changes so
SwiftUI keeps tile state and animates instead of rebuilding.

Mouse clicks inside a tile focus it via a local `NSEvent` monitor (`installClickMonitor`), because
the content is often an AppKit view that swallows SwiftUI gestures.

## Data flow for one server

```
TmuxModel.start()
  └─ every 2s: Remote.run(pollScript)
        pollScript = kill stale deck-* view sessions
                   + tmux list-panes -a -F '<fields>'
                   + cat ~/.claude/sessions/*.json for live pids
                   + capture-pane for every Claude pane
        └─ apply(): build sessions/windows/panes, derive WindowState,
                    parse Claude's footer/status line, prompts, suggestions,
                    fire notifications + sounds, save a restore snapshot
```

`WindowState` drives icons, badges and which view a tile shows:

```swift
enum WindowState { case claudeWorking, claudeNeedsYou, claudeReady, shell, running(String) }
```

`.running` (a foreground program that isn't a shell or Claude — vim, cloudflared…) forces the raw
terminal view, since those need a real terminal.

## Persisted state (`UserDefaults`, domain `io.github.tmuxdeck`)

| Key | Meaning |
|---|---|
| `hosts`, `activeHost` | connected servers; `host` is the legacy single-server key, migrated on launch |
| `forward.<host>` | port forwarding enabled for that server |
| `layout`, `layout.focused` | the split tree and focused leaf id |
| `collapsedGroups` | newline-joined keys of collapsed sidebar sections |
| `snapshot.<host>` | last known windows for that server, used by Restore |
| `plain.enabled`, `plain.terminals` | the plain-terminal section and its terminals (kind, folder, name) |
| `theme.selection` | `system`, `vscode`, or a theme file path |
| `showPRs`, `prs.allRepos` | PR panel visibility and repo filter |
| `statusbar.<kind>`, `statusbar.version` | which status chips are shown |
| `fontSize`, `sound.finish.*`, `sound.question.*` | terminal font size; completion/question sounds |

Files on disk:

- `~/Library/Caches/TmuxDeck/chats-v8/<session id>.json` — parsed transcript cache, so reopening a
  chat is instant. **Bump the `chats-vN` directory name whenever the parsed shape changes**,
  otherwise old caches deserialize into the new format and you get silently wrong chats.
- `~/Library/Application Support/TmuxDeck/Themes/` — imported `.json` / `.vsix` themes.
- `~/.cache/tmuxdeck/` **on the remote machine** — pasted screenshots uploaded for Claude.

## Remote.swift

One value type, two behaviours:

```swift
Remote(host: "tailscale110").run("tmux list-panes …")   // ssh, multiplexed
Remote(host: Remote.localHost).run("tmux list-panes …") // /bin/zsh -lc, this Mac
```

SSH options that matter: `ControlMaster=auto` + `ControlPath=~/.ssh/tmuxdeck-%C` (so a poll costs
milliseconds, not a handshake), `ClearAllForwardings=yes` (the app must never fight the user's own
SSH session for local ports — port forwarding is a separate `ssh -N` process in
`PortForwarder`), and `BatchMode=yes` (never hang waiting for a password prompt).

`run` also takes `Data` for stdin and has an `upload(_:fileName:)` helper.

## Where each feature lives

- **Restore lost sessions** — `TmuxModel.restoreCandidates()` / `restore(_:)`, UI in `RestoreView`.
  Sources: the app's own `snapshot.<host>` plus Claude Code's leftover session records.
- **Screenshot paste** — `ComposeBar.addImages`, uploads via `Remote.upload`, then pastes the path
  into Claude like a drag-and-drop would.
- **Status line chips** — `TmuxModel.footer()` scrapes the lines under Claude's input box;
  `StatusChip.parse` turns them into typed chips; `StatusLineEditor` edits the server-side script.
- **Task switcher thumbnails** — `AnsiThumbnail.swift` parses `capture-pane -e` output (SGR colour,
  256/true colour, bold/dim) and draws it into an `NSImage`. Captures are batched: one command per
  server, not one per window.
- **Themes** — `ThemeManager` discovers VS Code/Cursor/extension themes, follows `include` chains,
  parses JSONC (comments + trailing commas), and maps them onto `AppTheme`, which every view reads
  from `\.theme` in the environment.
