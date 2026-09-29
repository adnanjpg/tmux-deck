# tmux integration

tmux is the backend and stays the backend: it owns the processes, survives disconnects, and is what
makes a session still be there tomorrow. The app is a client that polls it and sends it commands.

## The incident to never repeat

The raw-terminal view attaches through a **grouped view session** (`deck-<session>-<rand>`) so it
can have its own current window without moving the user's other tmux clients around. That session
was originally created with:

```
tmux new-session -t a -s deck-a-1234 \; set destroy-unattached on
```

In tmux 3.4, `destroy-unattached` set on a session in a group **destroys the other sessions in that
group too** once nothing is attached. The user's laptop slept, every client disconnected, and tmux
destroyed sessions `a` and `b` — every window, every running Claude, the tunnel, everything. The
tmux server exited.

Rules that came out of it:

- **Never set `destroy-unattached`** (or any session-wide option that can propagate) on a view
  session.
- Stale `deck-*` sessions are cleaned up from the poll loop instead, and only when another session
  in the group still holds the windows:
  ```sh
  tmux list-sessions -F '#{session_name} #{session_attached} #{session_group_size}' \
    | awk '$1 ~ /^deck-/ && $2 == 0 && $3 > 1 {print $1}' \
    | while read -r s; do tmux kill-session -t "=$s"; done
  ```
- Test anything destructive on a throwaway server first: `tmux -L decktest …`.

The fallout also produced the **Restore** feature: the app snapshots each server's windows
(`snapshot.<host>`) and can rebuild sessions/windows in their folders, resuming Claude conversations
with `claude --resume <id>` — using Claude Code's own leftover session records when the app has no
snapshot of its own.

## Polling

One command every 2 seconds per server, combining several things so it's a single round trip:

1. clean up stale `deck-*` view sessions (above),
2. `tmux list-panes -a -F '<fields>'` — one line per pane, `:::`-separated,
3. every live `~/.claude/sessions/*.json`,
4. `capture-pane` for each pane that has a Claude session (colour off; the switcher is separate).

Fields collected per pane: session name, window id/index/name, `pane_current_command`,
`window_panes`, `window_active`, `pane_current_path`, `pane_id`, `pane_index`, `pane_active`,
`window_zoomed_flag`.

Panes are then grouped into windows. A window's "primary" pane is its Claude pane if it has one,
else the active pane. `paneItems` is only populated when a window has more than one pane — that's
what makes panes appear as sub-rows in the sidebar.

## Targeting

- **Always target pane ids (`%31`) where possible.** They're globally unique; `session:window` is
  not, and window indexes shift.
- `=` prefix means exact-match, no prefix search: `tmux kill-session -t "=deck-a-1234"`. Without it,
  a name that's a prefix of another can kill the wrong session.
- Commands that should act on what the user is *looking at* target the view session
  (`deck-…:@30`) so tmux's idea of "current" matches the app's.

## One terminal per tile

`TerminalController`s are keyed by **tile**, not by tmux session. A view session has exactly one
current window, so a session-keyed controller could only ever be in one tile — putting two windows
of the same session side by side used to show "Terminal shown in another tile" in the second one.
Each tile now attaches its own `deck-…` view session; they share the SSH connection, so the cost is
one extra tmux client each. Controllers whose tile is gone are dropped from the poll loop rather
than from `onDisappear`, which also fires while SwiftUI re-lays out.

Two tiles on two *panes of the same window* still fight over zoom, because zoom is a property of the
tmux window (below).

## Single-pane tiles and zoom

A tile showing one pane of a multi-pane window would otherwise render the whole window (tmux draws
all panes). The fix is to **zoom** that pane while the tile shows it:

```sh
tmux select-pane -t %31 && tmux resize-pane -Z -t %31      # select first: selecting another pane unzooms
```

`TerminalController` tracks the pane it zoomed and unzooms it when the tile goes away or switches
panes. Zoom is a property of the tmux window, so it's visible to other clients too — that's the
known trade-off.

## Capturing screens

- `capture-pane -p -t <pane>` — visible screen, plain text.
- `capture-pane -e -p -t <pane>` — keeps SGR colour escapes; used for switcher thumbnails
  (`AnsiThumbnail.swift` parses them).
- `capture-pane -p -J -S -3000` — with scrollback, joined wrapped lines; used by the console view
  and "Copy all output".
- Batch when capturing many panes — the switcher builds one command per server:
  ```sh
  for p in %1 %2 %3; do printf '@@P %s\n' "$p"; tmux capture-pane -e -p -t "$p"; done
  ```

## Writing remote shell that runs on Linux *and* macOS

Remote scripts run on the user's Linux servers and on this Mac (`Remote.localHost` → `/bin/zsh -lc`).
Both must work:

- **No `setsid` on macOS** — `if command -v setsid >/dev/null; then setsid nohup …; else nohup …; fi`.
- **BSD `sed` has no `\xNN`** — use `perl -pe 's/\xc2\xa0/ /g'` for the no-break space.
- Quote every interpolated value with `sq()` (single-quote escaping) — window names and paths
  contain spaces and quotes.
- zsh doesn't word-split unquoted variables, so `T="tmux -L x"; $T ls` fails. Use a function.

## Connection reality

SSH to the user's work machine drops often (minutes at a time). Design accordingly:

- Anything that must not half-finish runs detached on the remote side (see message sending in
  [claude-code-integration.md](claude-code-integration.md)).
- The poll loop just retries; `connected` flips and the sidebar shows it.
- `ControlMaster` multiplexing means a drop kills all in-flight calls at once — they must all be
  individually retryable.
