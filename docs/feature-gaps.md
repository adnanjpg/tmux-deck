# Feature gaps

What's obviously missing, audited 2026-09-30 against the code and against what comparable tools
offer (Claude Code's VS Code extension and desktop Code tab, Codex's IDE extension, Termius, iTerm2
tmux control mode, WezTerm, and the GUI-for-Claude-Code projects: Conductor, Crystal, Claude Squad,
vibe-kanban, opcode, claudecodeui).

This is a working list, not a plan. Update it as things land.

**Done since the audit** (2026-09-30): the diff view, the file browser and editor, opening finished
conversations, copy and search in the chat, notifications you can click and mute, the terminal
reconnecting itself, poll backoff and real error messages, Codex titles and resume, the chat view
for plain terminals, a sidebar filter, pinning, persisted drafts, accessibility labels, dependency
checks and ⌘/. What follows is what's left.

**The differentiator to protect:** every comparable tool has an open complaint that SSH sessions die
with the client and can't be reattached. tmux already solves that for us. The gaps are elsewhere.

## 1. The big ones

| Gap | Where it stands today |
|---|---|
| **Per-hunk accept / reject** | The diff view shows a worktree against its base branch, but it's read-only. Accepting or rejecting individual hunks, and leaving line comments that go back to the agent as a batch, is what the other tools do next. |
| **Creating worktrees** | The app reads worktrees; it doesn't make them. Conductor, Crystal, Claude Squad and vibe-kanban all create one per session, with a branch prefix and a way to copy gitignored files like `.env` into it. |
| **Checkpoints / rewind / fork** | Nothing. Revert the conversation, the code, or both from any message. |
| **A "what needs me" inbox** | The dock badge counts them and the sidebar can be filtered by text, but there's no filtered view of *blocked on approval* vs *working*. This becomes the main UX primitive past ~3 sessions. |
| **Search across conversations** | ⌘F searches the conversation you're in, and the history browser matches titles and first messages. Neither searches the *body* of every transcript. |
| **Export** | Copying works; there's still no save-to-file, Markdown/JSON export, share sheet or print. |
| **Commit and push from the app** | The diff view reads; it can't stage, commit, push or open a PR. |

## 2. Still partly true

**Notifications.** Clicking a banner opens its window, banners and sounds are configured
separately, both can be muted per server and per window, failures notify, and the wording follows
the assistant. Still missing: quiet hours, and a notification when a window or pane dies. It's still
transition-based, so anything that finished while the app was closed is announced only as the "Done"
pill.

**Codex.** Titles, restore-and-resume, the chat view, state badges and the send path are all there
now. Still Claude-only: structured question cards (`ComposeBar` requires `window.claude`),
stuck-message auto-Enter, queued-message display, and slash commands / `!` bash output / away-recaps
in the transcript. `codexState` still returns the `.claude*` states, so Codex windows pass every
`state.isClaude` filter and get run through Claude's screen parsers — harmless, but wasted work.

Codex also spawns subagents and guardian reviews, each with its own rollout. They're found in order
to be *excluded*; a subagent map — a tree with status, elapsed time and an openable read-only
transcript — is sitting there for free.

**Plain terminals.** They get the chat, state badges and notifications now. They're still not
durable: they die when the app quits and reopen in the same folder, which is precisely the property
tmux provides everywhere else, and Restore doesn't cover them.

## 3. Session management

No archiving, mark-unread, tags or colour labels. Servers can't be reordered, renamed or aliased.
The "Done" pill only clears when the window becomes *selected*, so a finished chat in an unfocused
tile shows Done indefinitely.

## 4. Errors and offline

The terminal reconnects, the poll backs off, failures are named rather than hidden in a tooltip, and
a chat that stops updating says so. What's left: **no offline mode** — with the server down you
still can't read a cached transcript, because a live chat tile requires a live window, even though
the parsed transcript is in the app's own cache. (Past conversations can be opened, but only while
the server answers.)

Failed image uploads still only turn the thumbnail red, with no retry.

## 5. Single window by construction

`Window(id: "main")`, not `WindowGroup`; no `openWindow` anywhere. You can't put one conversation on
a second monitor or tear a tile off. The substitute is in-window tiling, capped at 6 tiles. This is
a deliberate design choice ([architecture.md](architecture.md)) — worth revisiting, not a bug.

## 6. Accessibility

The state badges, window icons, connection dot, send and stop buttons and the sidebar menus have
labels now. Still missing: labels on the usage gauges and status chips, **no Reduce Motion handling**
for the spring, pulse and phase animations, and splitting still needs drag and drop — the only
keyboard route is a context-menu item with no shortcut.

## 7. Preferences and onboarding

Notifications are configurable independently of sound now, and ⌘/ lists the shortcuts. Each server
reports which of `python3`, `claude`, `codex` and `gh` it's missing, and what that costs you.

Still no setting for the poll interval, the default assistant for ⌘N, the default folder or shell for
plain terminals, scrollback size, confirm-before-close, chat density, keyboard-shortcut
customisation, or clearing the transcript cache. No tour.

## 8. Table stakes seen elsewhere that we still do not have

Permission-mode selector switchable mid-session; plan mode as an editable document; an @-mention file
picker with fuzzy match; a slash-command palette and GUI browsers for skills/hooks/MCP/plugins;
per-session cost rolled up across sessions with attribution by skill and subagent; a kanban/queue
view; run/preview scripts per worktree; cloud sync of servers and layout; snippets (reusable command
macros across hosts); mobile companion access for approving permissions.
