# Feature gaps

What's obviously missing, audited 2026-09-30 against the code and against what comparable tools
offer (Claude Code's VS Code extension and desktop Code tab, Codex's IDE extension, Termius, iTerm2
tmux control mode, WezTerm, and the GUI-for-Claude-Code projects: Conductor, Crystal, Claude Squad,
vibe-kanban, opcode, claudecodeui).

This is a working list, not a plan. Update it as things land.

**The differentiator to protect:** every comparable tool has an open complaint that SSH sessions die
with the client and can't be reattached. tmux already solves that for us. The gaps are elsewhere.

## 1. The big ones

| Gap | Where it stands today |
|---|---|
| **Diff review** | There is no diff view anywhere. The reader sends a 400-character summary and a line count (`ChatStore.swift`), never the `old_string`/`new_string`/patch content, so you can see *that* 12 lines of `foo.swift` changed and never *what*. This is the most-cited reason people leave the terminal for a GUI, and usually comes with per-hunk accept/reject and line comments. |
| **Opening a past conversation** | Impossible. A chat tile needs a live tmux pane (`ContentView.windowContent`), even though the parsed transcript is sitting in `~/Library/Caches/TmuxDeck/chats-v9/`. Nothing enumerates `~/.claude/projects` or `~/.codex/sessions`. The only route back is Restore, which *relaunches* the session and burns context. |
| **Search** | Only the console's AppKit find bar, and the README's advertised ⌘F is bound nowhere. No search inside a conversation, across conversations, in the sidebar, in the raw terminal (SwiftTerm ships a `SearchEngine` we never use), or in the ⌃⇥ switcher. |
| **Copy anything from the chat** | No context menu in `ChatView` at all — no copy message, copy code block, copy tool output. ⇧⌘C copies the *terminal screen*, not the conversation you're looking at. No export of any kind. |
| **Remote files** | No way to open a file, reveal it, or edit one. For a remote host there's no fetch-file path at all. An SFTP-style browser plus remote editing is the most-used non-terminal feature in SSH GUIs. |
| **Git beyond the PR panel** | `git remote get-url origin`, used only to resolve `#123`. No branch, status, diff, commit, push, or worktree support — and a worktree per session is what every parallel-agent tool converged on. |
| **Checkpoints / rewind / fork** | Nothing. Revert the conversation, the code, or both from any message. |
| **A "what needs me" inbox** | The dock badge counts them, but there's no filtered view of *blocked on approval* vs *working*. This becomes the main UX primitive past ~3 sessions. |

## 2. Notifications are half-built

Transitions fire a banner and a sound (`TmuxModel.notifyStateChanges`), and that's the whole system.

- Plain (no-tmux) terminals have no state machine, so a local Claude finishing is completely silent.
- Nothing notifies for a *failure*: SSH down, restore failure, send failure get a 2.5-second toast.
- Banners are inert — no `categoryIdentifier`, no `UNUserNotificationCenterDelegate`, so clicking one
  can't focus the window, and you can't reply from it.
- No per-window or per-server mute, no quiet hours, no banner/sound split, and no separate routing
  for *finished* vs *blocked on approval* — the second is the one people want pushed to a phone.
- The text says "Claude" even for Codex windows.
- It's transition-based, so anything that finished while the app was closed is never announced.

## 3. Codex is a second-class citizen

Implemented for Claude, missing for Codex: conversation titles; structured question cards
(`ComposeBar` requires `window.claude`); stuck-message auto-Enter and its explanation; queued-message
display; slash commands, `!` bash output, away-recaps and compaction notices in the transcript;
resume on restore (`claude --resume <id>` vs a bare `codex`, and Codex sessions aren't discovered by
`restoreCandidates` at all); image counts in the newer record shape; deletions in a `FileChange`
(hardcoded `rem=0`).

Also: `codexState` returns the `.claude*` states, so Codex windows pass every `state.isClaude` filter
and get fed through Claude's screen parsers — `footer()`, `activity()`, `suggestion()`,
`promptOptions` all look for Claude's glyphs and rules. Those produce nothing useful for Codex rather
than anything harmful, but they're wasted work and a source of wrong-looking UI.

Codex also spawns subagents and guardian reviews, each with its own rollout
([codex-cli-integration.md](codex-cli-integration.md)). We find them in order to *exclude* them.
A subagent map — a tree with status, elapsed time and an openable read-only transcript — is sitting
there for free.

## 4. Plain terminals are a third-class citizen

A local `claude` or `codex` started as a plain terminal gets raw SwiftTerm and nothing else: no chat
view, state badge, notification, compose bar, question cards, status bar, suggestions,
stuck-message recovery, image paste, or ⇧⌘C. The app *already* finds that process's Claude session
record and transcript — it uses it only to pick a window title (`PlainTerminals.refreshInfo`).

Note the boundary: "This Mac — tmux sessions" has the full feature set. The gap is specifically
*no-tmux*, not *local*.

## 5. Session management

No renaming a conversation (the title is Claude's own; a tmux rename is ignored when
`name == command`). No pinning, archiving, mark-unread, tags or colour labels. No sidebar
search/filter, manual sort or custom grouping. Servers can't be reordered, renamed or aliased.
Drafts aren't persisted across quit. The "Done" pill only clears when the window becomes *selected*,
so a finished chat in an unfocused tile shows Done forever.

## 6. Errors and offline

- **The raw terminal never auto-reconnects** — `TerminalController` says so outright; recovery is a
  manual button. A flaky link leaves the pane dead until clicked.
- **`ChatStore.poll()` swallows every failure** (`guard result.ok else { return }`). No error state,
  no "transcript is stale" marker — the chat silently stops updating while looking live.
- **No backoff**: the 2-second poll keeps firing at full rate against a dead host, each spawning an
  ssh with a 15-second timeout.
- `lastError` only ever appears as a tooltip. No Retry-now, no error log.
- Nothing distinguishes *host unreachable* from *auth failed* from *tmux not running* — the poll
  script even emits a `@@NOSERVER` sentinel that **no Swift code reads**.
- **No offline mode**: with the server down you can't read the cached transcript, because a chat tile
  requires a live window.

## 7. Single window by construction

`Window(id: "main")`, not `WindowGroup`; no `openWindow` anywhere. You can't put one conversation on
a second monitor or tear a tile off. The substitute is in-window tiling, capped at 6 tiles. This is
a deliberate design choice ([architecture.md](architecture.md)) — worth revisiting, not a bug.

## 8. Accessibility — not started

`grep -rn accessibility Sources/` returns **zero hits**. Icon-only controls rely on `.help()`
tooltips, which VoiceOver doesn't read as labels (Copy output, the + menu, Stop/Send, the status
chips). State is conveyed by colour alone in several places (window icons, session dots, the
connected dot, usage gauges). No Reduce Motion handling for the spring, pulse and phase animations.
Splitting requires drag and drop; the only keyboard route is an undiscoverable context-menu item.

## 9. Preferences and onboarding

Settings is two tabs: two sound toggles, a text-size stepper, and themes. No setting for the poll
interval, notifications independent of sound, the default assistant for ⌘N, the default folder or
shell for plain terminals, scrollback size, confirm-before-close, or clearing the transcript cache.

Onboarding checks `tmux` on the server and nothing else — not `python3` (**required for every chat
view**, and its absence fails silently), `claude`, `codex` or `gh`. There's no shortcut cheat-sheet
in the app; the table lives only in the README.

## 10. Table stakes seen elsewhere that we don't have

Permission-mode selector switchable mid-session; plan mode as an editable document; an @-mention file
picker with fuzzy match; a slash-command palette and GUI browsers for skills/hooks/MCP/plugins;
per-session cost rolled up across sessions with attribution by skill and subagent; a kanban/queue
view; run/preview scripts per worktree; cloud sync of servers and layout; snippets (reusable command
macros across hosts); mobile companion access for approving permissions.
