# Codex CLI integration

Tmux Deck starts Codex with the plain `codex` command in the selected tmux session's working
directory, or in a local plain terminal. It adds no model, approval, sandbox or network flags, so
the Codex configuration already on that machine stays authoritative.

Codex windows get the **same native chat view as Claude** (`ChatView` + `ChatStore`), read from
Codex's own transcript. The raw terminal is still one keystroke away (⌥⌘T) for the session picker,
slash commands and anything else that only exists in the TUI.

## Where the transcript lives

Codex writes one JSONL **rollout** per thread:

```
~/.codex/sessions/YYYY/MM/DD/rollout-<local-start-time>-<uuid>.jsonl
```

The first line is a `session_meta` record with `cwd`, `session_id`, `originator`, `source` and
`thread_source`.

## Matching a pane to its rollout — the part that bites

Claude Code writes `~/.claude/sessions/<pid>.json` naming its tmux pane. **Codex writes nothing
like that**, so `codexFinder` (in `TmuxModel.swift`, runs on the server each poll) has to work it
out:

1. Walk the process tree down from `pane_pid` to the `codex` process.
2. Read its start time (`ps -o lstart=`, same format on macOS and Linux).
3. Among rollouts whose `session_meta.cwd` is the pane's folder and whose mtime is after that start,
   prefer the one whose **file name** time is within a few minutes of it; otherwise take the most
   recently written (which is what `codex resume` looks like — old name, live file).

**The trap:** Codex spawns subagents and "guardian" reviews, and each one gets its own rollout, in
the same folder, usually written *more recently than the conversation itself*. Matching on "newest
file in this folder" therefore shows a subagent's transcript — a message you sent sits on "sending"
forever while Codex is visibly answering on screen. Only threads with **no `parent_thread_id` and
`thread_source == "user"`** are the conversation.

## Two record formats

Which one a session uses is fixed when it starts, so `codexReader` decides once from the head of the
file (`"item_completed"` present or not).

| | Newer | Older |
|---|---|---|
| Messages | `event_msg` / `item_completed` with `item.type` `UserMessage`, `AgentMessage`, `Reasoning`, `CommandExecution`, `FileChange`, `Extension` | `event_msg` / `user_message`, `agent_message`, `patch_apply_end`, `web_search_end` |
| Model exchange | `response_item` records — skipped, they duplicate the above | `response_item` `message` / `reasoning` / `function_call` / `custom_tool_call` and their outputs |

Notes that cost time:

- Assistant turns are logged **twice** in the older format (the TUI event and the model-facing copy);
  the second is dropped by text.
- A compaction **replays** the last user message; it's shown once.
- `custom_tool_call.input` is JavaScript calling `tools.exec_command({cmd: "…"})`. The `cmd` key is
  quoted in some versions and bare in others — the summary regex allows both, or you get the
  JavaScript wrapper in the tool row.
- Tool output is wrapped in a `Script completed / Wall time … / Output:` header with one JSON object
  per chunk; `unwrap()` pulls the real text out and reads the exit code for the error flag.
- `CommandExecution` already carries `parsed_cmd[0].cmd`, `exit_code` and `formatted_output`, which
  is why the newer format is preferred wherever it exists.

The reader emits the **same records as the Claude reader** (`k: user|text|thinking|tool|result|note`),
so `ChatStore`, `ChatView`, the compose box, the disk cache and pending-message confirmation all work
unchanged.

## Sending, state and colour

- Sending waits for Codex's `›` prompt marker, where Claude's is `❯` — same retry loop otherwise
  (see [claude-code-integration.md](claude-code-integration.md)).
- Codex keeps no status file, so `codexState` reads the footer: `esc to interrupt` means working, an
  approval prompt means it needs you.
- Codex probes the terminal at startup with `ESC[6n ESC]10;? ESC]11;? ESC[?u ESC[c` and picks its
  palette from the answer. SwiftTerm answers OSC 11 from `terminal.backgroundColor`, and tmux relays
  it — but only if the outer terminal answers, and only with whatever colour the terminal had *at
  that moment*. That's why terminals must re-apply their colours when macOS switches appearance
  (see [appkit-and-swiftterm.md](appkit-and-swiftterm.md)); before that fix, Codex drew white text on
  a white background.

## Restore

Restoring a saved Codex window starts a **new** interactive session in the saved folder. There's no
equivalent of `claude --resume <id>` wired up, so it doesn't reopen the previous conversation.
