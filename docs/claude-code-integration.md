# Talking to Claude Code

The app never embeds Claude — Claude Code runs as a normal CLI inside a tmux pane. Everything the
chat view shows is reconstructed from two things Claude Code leaves on disk, plus scraping its
screen. None of this is a public API; it can change with any Claude Code release, so keep the
parsing defensive and fail soft.

## 1. Session records — which pane is which conversation

`~/.claude/sessions/<pid>.json`, one per running session:

```json
{
  "pid": 3465405,
  "sessionId": "5e66fd4e-fe3c-4beb-b63e-32f8f388300e",
  "cwd": "/home/user/project",
  "tmux": "a:@30.%30",          // session : window . pane
  "status": "idle",
  "waitingFor": null,
  "name": "unirefund-fb"
}
```

- The `tmux` field is how a pane is matched to a conversation. Parse the **pane** id (`%30`) — pane
  ids are globally unique, window ids are not ambiguous either but panes are what we capture.
- A record is only live if its pid is alive (`kill -0`). Stale files linger for dead sessions and
  are what the Restore feature mines.
- `status` seen in the wild: `idle`, `busy`, `running`, `working`, `compacting`, `waiting`,
  `blocked`, `shell`. Treat `busy`/`running`/`working`/`compacting` as working. **`shell` means idle
  with a background shell**, not busy — reading it as busy made finished sessions look stuck.
- The file is rewritten frequently. A read that lands mid-write returns nothing, which used to make
  a chat flicker to "Starting Claude…". `TmuxModel` therefore *bridges* a missing record for 20s
  (`lastClaude`) instead of believing it instantly.

## 2. The transcript — what the chat renders

`~/.claude/projects/<slugified cwd>/<sessionId>.jsonl`, one JSON object per line, appended forever
(they reach tens of MB). `ChatStore` reads it incrementally by byte offset and caches the parsed
result; the reader is a Python script sent over stdin (`ChatStore.reader`) so the parsing happens on
the remote machine and only the distilled result crosses the network.

Record types that matter:

| `type` | What it is |
|---|---|
| `user` | your message; `message.content` is a string or an array of parts |
| `assistant` | Claude's turn: `text`, `thinking`, `tool_use` parts |
| `user` with `tool_result` parts | the output of a tool call, matched by `tool_use_id` |
| `attachment` + `attachment.type == "queued_command"` | **a message you sent while Claude was busy** |
| `queue-operation` (`enqueue`/`dequeue`/`remove`) | the pending-message queue |
| `system` + `subtype == "local_command"` | a slash command (`<command-name>/rename</command-name>`) and, separately, its output |
| `system` + `subtype == "compact_boundary"` | conversation was compacted |
| `system` + `subtype == "away_summary"` | Claude's "while you were away" recap |
| `custom-title` / `ai-title` | the conversation's name (a `/rename` beats the generated one) |
| `continued-in` | this conversation continues in another session id |

Traps found the hard way:

- **Queued messages are not `user` records.** Send something while Claude is working and it is
  logged as a `queued_command` attachment. Ignoring those made ~6 of the user's messages vanish from
  the chat. Show them, and show still-pending ones from `queue-operation` as "Queued".
- **Slash commands hide in `system` records.** `/rename` never appears as a user message; it's a
  `system`/`local_command` record holding `<command-name>`, followed by a second record with
  `<local-command-stdout>`.
- **`isMeta` records** carry things like away summaries — skipping all meta dropped them.
- **Tagged noise to hide:** `<command-message>`, `<local-command-caveat>`, `<system-reminder>`,
  `<bash-input>`/`<bash-stdout>` (shown as `!` commands instead), `<task-notification>` (shown as a
  small note, and *never* as one of your messages), `<pasted_content>` wrappers (unwrap them).
- Claude Code merges several queued messages into one delivery, so matching "did my message
  arrive?" must be containment, not equality (see below).

## 3. Screen scraping — status, questions, suggestions

Read with `tmux capture-pane -p` (add `-e` to keep colour, used for switcher thumbnails).

**Claude's prompt is `❯` followed by U+00A0, a no-break space.** Every naive `grep '❯ '` fails
silently. Normalise with `perl -pe 's/\xc2\xa0/ /g'` — not `sed`, whose BSD build on macOS doesn't
understand `\xNN` (these scripts run on both Linux and this Mac).

Layout of a Claude screen, bottom-up:

```
  … conversation …
  ✻ Working… (12s · ↓ 1.2k tokens)        ← activity line (TmuxModel.activity)
  ────────────────────────────────────    ← rule
  ❯ your input                            ← input line (typed text + dim suggestion)
  ────────────────────────────────────    ← rule
  user@host:/path [Opus 5] high ctx:15%   ← status line  ┐ footer(): everything
  ⏵⏵ auto mode on · 6 agents              ← mode line    ┘ below the last rule
```

- `TmuxModel.footer()` returns the lines below the last rule → `StatusChip.parse` turns them into
  typed chips (model, effort, context %, usage %, permission mode, PRs, shells, agents).
- `TmuxModel.typedInput()` returns what's actually typed, skipping the *dim* (SGR `2`) suggestion
  text; `suggestion()` returns the dim text when nothing is typed.
- Permission prompts are numbered choices (`❯ 1. Yes`); the question text is whatever sits above the
  first numbered line. Richer questions (`AskUserQuestion`) come from the transcript instead, where
  the full option list with descriptions is available — the screen only has the labels.
- If a read finds no status line (mid-redraw, or a menu covering it), reuse the last good one for a
  minute rather than blanking the chips.

## 4. Sending a message reliably

This is the part that broke most often. `TmuxModel.send(text:images:to:)` does:

1. Upload the text, then run the actual send from a **detached** job on the remote machine
   (`setsid nohup …`, falling back to plain `nohup` because **macOS has no `setsid`**). A dropped
   SSH connection mid-send used to leave the text pasted but never submitted.
2. Paste via `load-buffer` + `paste-buffer -p` (bracketed paste) so a multi-line message arrives as
   one message.
3. **Wait until the text actually appears in Claude's input line**, then press Enter, then keep
   checking and re-pressing (up to 4 times). Claude swallows an Enter that lands while it's still
   ingesting a paste, and for `/commands` the first Enter only accepts the autocomplete entry.
4. The app also re-checks on every 2s poll: if a sent message is still sitting in the input box it
   presses Enter again (3 tries), and if Claude's **agent list** has focus it says so instead —
   pressing ← in an empty box opens that list, and from then on Enter goes to the list, not the
   message. (The compose box therefore does not forward ←/→ to Claude.)

Confirming delivery: a pending message is cleared when its normalised text is **contained in** any
logged user message or queue entry (Claude merges queued messages, so equality fails). Slash
commands are never confirmed this way — they don't appear as chat messages — so they're not tracked
as pending at all.

## 5. Driving Claude's UI from the app

- **Permission answers** — send the choice's digit (`send-keys -l 1`).
- **Mode changes** — `Shift+Tab` (`BTab`) repeatedly until the mode line shows the wanted mode, up
  to 7 times, then give up and say the mode isn't available in that session.
- **Model / effort** — send `/model <id>` / `/effort <level>` as a normal message.
- **`/usage`, `/tasks`** — send the command, wait ~2s, `capture-pane`, then `Escape` to close it.
  Only offered when Claude isn't working, since it briefly takes over the screen.
- **Stop** — `Escape`.
- **Images** — upload to `~/.cache/tmuxdeck/` on the remote machine, then paste each absolute path
  into the input before the message text, exactly as dragging a file into the terminal would.
