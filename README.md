# Tmux Deck

A native macOS app for working with tmux sessions on a remote machine over SSH, built for running [Claude Code](https://claude.com/claude-code) sessions in tmux.

tmux stays the backend. Your sessions keep running on the server when the app closes, your Wi-Fi drops, or your laptop sleeps. The app gives you a regular Mac interface on top:

- **Sidebar of sessions, windows and panes.** Click to switch. Claude windows are named after their conversation title, not "claude" over and over.
- **Claude windows as a chat.** Your messages, Claude's formatted replies, and each tool call as a row you click to expand. Slash commands (like `/rename`) and `!` shell commands show with their output, along with background task notices, compaction, errors and Claude's "while you were away" recaps. Text selects and copies like any Mac app. Conversations are cached on disk, so switching is instant.
- **A real Mac input box.** ⌘A, ⌥⌫, ⌘⌫, ⌥←/→, ⌘Z and mouse selection all work. Enter sends, Shift+Enter adds a new line. Claude's suggested next message shows faded; Tab takes it.
- **Buttons for Claude's permission questions**, a Stop button, and status in the sidebar (working, needs your answer, ready).
- **Claude's live progress:** its status line ("Computing… 18s · ↓ 547 tokens"), to-do list and thinking.
- **Your message shows the moment you send it,** greyed out until Claude's log confirms it arrived.
- **Paste or drop screenshots** into the input box. They upload to `~/.cache/tmuxdeck` on the server and are sent to Claude as images.
- **A status bar** that mirrors Claude Code's status line as native chips: model, effort, context used, 5-hour and weekly usage with reset time, permission mode, PRs, shells and agents. Click a chip to change the mode, model (current and legacy) or effort, see weekly and other usage limits, jump to another Claude session, or see background commands. Choose what it shows with the slider button, and edit Claude's status line command or script from there, with a Test button before saving.
- **A sound, Dock badge and notification** when a Claude session finishes or needs you. Pick the sounds in Settings (⌘,).
- **Plain shell windows as a console:** selectable, searchable output (⌘F) with the same input box.
- **Every tmux action as a button or menu item:** new window or session, split, even out panes, zoom, swap, move a pane into its own window or into another window, move windows between sessions, rename, close. You can also drag panes and windows around in the sidebar.
- **A raw terminal view** (⌥⌘T) for anything interactive, like vim or htop.
- **Restore lost sessions.** The app remembers each server's sessions and windows. If tmux loses them (a crash, a reboot), the sidebar offers Restore previous sessions: pick windows and it recreates them in their folders, resuming each Claude conversation with `claude --resume`. It also uses the session records Claude Code leaves on the server, so it can recover Claude windows it never saw. Also in each server's ••• menu.
- **Split view.** Drag a window from the sidebar onto the main area: drop on an edge to split left, right, above or below, or in the middle to replace. Drag a tile's title bar to move it, drag the dividers to resize, ✕ to close a tile, or ⇧⌘U to go back to one. Right-click a window for Open to the right / Open below. Clicking a window in the sidebar opens it on its own (or focuses its tile if it's already on screen). Splits nest, animate, and are remembered.
- **Several servers at once.** Add servers from the + button (it lists the hosts in your `~/.ssh/config`); each gets its own section in the sidebar.
- **Port forwarding per server.** Turn it on in a server's ••• menu to run that host's `LocalForward` rules from your SSH config in the background. It reconnects on its own and shows which ports are forwarding and which are already taken on your Mac.
- **Pull requests at a glance.** A side panel (⇧⌘P) lists your open PRs and ones waiting for your review for the open window's repository (or all repos), highlights the PRs mentioned in the open chat, with approval status and CI results (passed / failed / running). PR links in chats become live chips; hover for approvals and failing checks, click to open. Uses the GitHub CLI (`gh`), which must be installed and signed in on your Mac.

## Requirements

- macOS 14 or later, with Xcode or the Xcode command line tools (Swift 6.2+).
- A machine you can reach with `ssh <host>` **without a password prompt** (SSH key or agent). An entry in `~/.ssh/config` works well.
- tmux 3.2 or later on that machine.
- Python 3 on that machine (only for the Claude chat view).
- Claude Code on that machine, if you want the chat view. Without it, everything else still works.

## Build and install

```bash
git clone https://github.com/adnanjpg/tmux-deck.git
cd tmux-deck
./build-app.sh
```

This builds a release version, packages `Tmux Deck.app`, signs it locally (ad hoc, no Apple developer account needed), and installs it in `~/Applications`. Open it from there or from Spotlight. On first launch it asks for your SSH host.

To update, `git pull` and run `./build-app.sh` again.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New Claude window | ⌘N |
| New terminal window | ⌘T |
| Split right / down | ⌘D / ⇧⌘D |
| Copy the whole window | ⇧⌘C |
| Show as raw terminal | ⌥⌘T |
| Pull requests panel | ⇧⌘P |
| Close other tiles | ⇧⌘U |
| Previous / next window | ⌘[ / ⌘] |
| Go to window 1–9 | ⌘1 … ⌘9 |

## How it works

- Every remote call goes over one shared SSH connection (`ControlMaster`), so refreshes and button clicks are fast. Port forwards from your SSH config are skipped on that connection (`ClearAllForwardings`); when you turn on port forwarding for a server, a separate `ssh -N` connection runs them.
- The sidebar refreshes every 2 seconds from `tmux list-panes`.
- Claude Code writes a record for each running session in `~/.claude/sessions/<pid>.json`, including its tmux pane and status. The app uses that to match windows to conversations, then reads new lines from the conversation log in `~/.claude/projects/`. Nothing is installed on the server; the small Python reader is sent over SSH each time.
- Messages you send are pasted into the pane with tmux's bracketed paste, so multi-line messages arrive as one.
- The raw terminal view attaches to a private tmux session grouped with yours (`deck-…`). It has its own current window, so it never moves your other tmux clients around, and the app closes leftover ones itself (only when your real session still holds the windows).
- Sounds and font size are in Tmux Deck → Settings (⌘,). Servers are added and removed from the sidebar.

## Limitations

- The chat view shows the main conversation only, not subagents' inner steps.
- Claude's status and permission choices are read from its screen and session record, so a future Claude Code release could need small fixes.
- If you type into Claude from somewhere else, the half-typed text doesn't appear in the app's box. Sent messages always show up.

## Credits

The terminal view uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza (MIT). It's vendored in `Vendor/SwiftTerm` at commit `73b27f5`, trimmed to its sources, with a simplified `Package.swift` so the build needs no extra downloads.

## License

MIT. See [LICENSE](LICENSE).
