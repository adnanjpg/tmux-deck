# Working on Tmux Deck

A native macOS app (SwiftUI + AppKit) that fronts **tmux** sessions — local or over SSH — and
renders **Claude Code** windows as a real Mac chat instead of a terminal. See [README.md](README.md)
for what it does from a user's point of view; this file is for whoever (or whatever) is editing it.

## Build, install, run

```bash
swift build              # compile only — fast check while iterating
./build-app.sh           # release build + bundle + ad-hoc sign + install to ~/Applications
```

`build-app.sh` installs `~/Applications/Tmux Deck.app` (bundle id `io.github.tmuxdeck`).
There is no Xcode project; it's a SwiftPM package with a vendored SwiftTerm (see
[docs/appkit-and-swiftterm.md](docs/appkit-and-swiftterm.md)).

**The app does not restart itself after a rebuild.** A window that's already open keeps running the
old binary until it's quit and reopened — this silently wasted days once. `UpdateWatcher` now
notices the binary changed and shows a "newer build installed" banner with a Relaunch button, but
when you're verifying your own change, quit and reopen it yourself:

```bash
osascript -e 'tell application "Tmux Deck" to quit'
open ~/Applications/"Tmux Deck.app"
```

## House rules

1. **Commit and push after every change.** Don't batch, don't wait to be asked. Someone else builds
   this repo from source and should get fixes immediately. GitHub is slow from here, so push with
   `git -c http.postBuffer=524288000 push`.
2. **Keep these docs in sync with the code.** This repo is worked on by multiple agents in parallel;
   docs are the shared memory. If you change behaviour, fix the doc in the same commit. If you learn
   something painful (a platform gotcha, a format quirk, a wrong assumption), write it down here —
   that's what the "Hard-won gotchas" section is for.
3. **Verify before claiming.** Build it, install it, and check the actual behaviour. Screenshot the
   real window (`screencapture -l <windowID>`) rather than asserting it looks right. If you couldn't
   verify something, say so plainly instead of implying you did.
4. **Never test destructive tmux commands against real sessions.** Use a throwaway server:
   `tmux -L decktest …`. A `destroy-unattached` experiment once killed every real session and every
   Claude process on the user's work machine. See [docs/tmux.md](docs/tmux.md).
5. **Be careful with synthetic keystrokes.** Driving the keyboard via System Events is useful for
   testing shortcuts, but if focus slips the keys land in whatever app is frontmost — this has
   switched the user's browser tabs mid-session. Check frontmost and send keys in the *same*
   AppleScript, and don't do it at all when the user is likely working.
6. **No personal data in the repo.** No real hostnames, company names, paths with the user's name,
   or SSH details. The app asks for a host on first launch; `localHost` is the only special value.

## Architecture in one page

Everything runs in one window. "Tabs" are not OS windows — they're data (`tag` strings) rendered
into split-view tiles on demand.

| Layer | Files | Role |
|---|---|---|
| Entry, menus, settings | `App.swift` | Scene, keyboard shortcuts, Settings tabs, `AppDelegate` |
| Servers | `AppModel.swift` | All connected servers, port forwarding, grouped tab list |
| One server | `TmuxModel.swift` | Polls tmux, owns sessions/windows/panes, all tmux actions |
| Transport | `Remote.swift` | Runs a command on a host — SSH (multiplexed) or local zsh |
| Sidebar + tiles | `ContentView.swift` | Sidebar, toolbar, dialogs, which view fills a tile |
| Split view | `SplitLayout.swift` | Layout tree, drag/drop, resize, `LayoutModel` (focus, ⌘W) |
| Claude chat | `ChatView.swift`, `ChatStore.swift` | Reads the transcript, renders turns/markdown/tables |
| Input | `ComposeBar.swift` | The message box, image paste, Claude's question cards |
| Raw terminal | `TerminalController.swift`, `TerminalPane.swift` | SwiftTerm attached to a tmux view session |
| Plain terminals | `PlainTerminals.swift` | Shells/Claude on this Mac with no tmux at all |
| Console | `ConsoleView.swift` | Non-Claude tmux window as selectable text |
| Status bar | `StatusBar.swift`, `StatusLineEditor.swift` | Claude's status line as native chips |
| Task switcher | `TabSwitcher.swift`, `AnsiThumbnail.swift` | ⌃⇥ HUD with rendered screen thumbnails |
| Themes | `Themes.swift` | Reads VS Code themes, applies them everywhere |
| PRs | `PullRequests.swift` | `gh`-backed PR panel and inline PR chips |
| Misc | `MacKeys.swift`, `UpdateWatcher.swift` | Mac editing keys in terminals; stale-build banner |

Details, including the `tag` format and every persisted key:
[docs/architecture.md](docs/architecture.md).

## Hard-won gotchas

Read these before touching the related area — each one cost real debugging time or real damage.

- **`destroy-unattached` destroys the *real* session too** when set on a grouped view session. It
  wiped every window on the user's server. Never set it. → [docs/tmux.md](docs/tmux.md)
- **Custom AppKit views need `acceptsFirstMouse`.** Without it the first click into the app after
  it loses key status is swallowed, and the UI looks frozen until you click twice.
  → [docs/appkit-and-swiftterm.md](docs/appkit-and-swiftterm.md)
- **Claude's prompt uses a no-break space** (`❯` + U+00A0). `grep '❯ '` silently never matches.
  → [docs/claude-code-integration.md](docs/claude-code-integration.md)
- **Enter gets swallowed while Claude ingests a paste**, and ← opens Claude's agent list which then
  eats Enter. Sending a message is a retry loop in a detached job, not one `send-keys`.
  → [docs/claude-code-integration.md](docs/claude-code-integration.md)
- **Messages sent while Claude is busy** are logged as `queued_command` attachments, not as user
  messages. Miss that and they vanish from the chat.
  → [docs/claude-code-integration.md](docs/claude-code-integration.md)
- **macOS has no `setsid`,** and BSD `sed` doesn't take `\xNN` escapes. Remote scripts run on Linux
  *and* on this Mac. → [docs/tmux.md](docs/tmux.md)
- **SSH to the work machine drops constantly.** Anything that must not half-finish has to survive a
  dead connection. → [docs/tmux.md](docs/tmux.md)

## Testing

[docs/testing.md](docs/testing.md) — throwaway tmux server, screenshotting the real window, what to
check after a change, and the keystroke-simulation trap.
