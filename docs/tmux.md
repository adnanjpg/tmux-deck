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

## The view client must not resize shared windows

Other tmux clients (an editor's terminal, another machine) are attached to the same windows, and
tmux sizes a window to its most recent client by default (`window-size latest`). A tile would
therefore resize the shared window — and every Claude in it would redraw — on layout restore, on
reconnect, whenever a tile changed. So the view session is attached with the client flag:

```sh
tmux new-session -f ignore-size -t a -s deck-a-1234 \; set status off \; set mouse on
```

`ignore-size` (tmux ≥ 3.2) leaves the deck client out of the sizing. The trade: a window sized by
someone else's client is shown clipped in a smaller tile. Verified on a throwaway server: a
60-column `ignore-size` client leaves a 150-column window at 150; a plain client shrinks it to 60.

## Single-pane tiles and zoom

A tile showing one pane of a multi-pane window would otherwise render the whole window (tmux draws
all panes). The fix is to **zoom** that pane while the tile shows it:

```sh
tmux select-pane -t %31 && tmux resize-pane -Z -t %31      # select first: selecting another pane unzooms
```

`TerminalController` tracks the pane it zoomed and unzooms it when the tile goes away or switches
panes. Zoom is a property of the tmux window, so it's visible to other clients too — that's the
known trade-off.

## Reordering from the sidebar

Sidebar rows use `.onDrag` (not `.draggable`): it is the only hook that fires when a drag *starts*,
and `SidebarDrag.current` has to know what is being dragged before the drop, because the drop
delegate can only read the payload on drop. The row's `WindowDropTarget` shows a line above or
below the row (top/bottom half of the row, from `DropInfo.location`), or lights the whole row when
a pane is being dragged, since a pane drop *joins* the window.

- Window onto a window: `tmux move-window -b|-a -s <src> -t <dst>` (before/after; works across
  sessions). `placeWindow` reorders `sessions` locally first so the row moves at once; the next poll
  replaces that with tmux's answer.
- Window onto a session header: `move-window -t session:` (to the end).
- Pane onto a window: `join-pane -h`; pane onto a header: `break-pane` into that session.
- Dropping onto a tile in the main area is a different thing: it splits the layout
  (`SplitLayout.swift`, `DropZone`), which is app-side only. tmux is not involved — each tile is
  its own grouped client, so nothing in tmux needs configuring for side-by-side tiles.

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
- **Only one connection per host may open the control socket.** With every call using
  `ControlMaster=auto`, the burst at startup races: one wins and the rest print
  `ControlSocket … already exists, disabling multiplexing` and then open connections of their own,
  slowly. Reproduced with six concurrent calls — five warnings. `SSHMaster` (in `Remote.swift`)
  makes the first call for a host run alone and everything else wait for it; after that the socket
  exists and they just attach. Same test afterwards: no warnings.
- **sshd allows 10 sessions per connection (`MaxSessions`), and everything shares one.** Each
  command and each raw terminal's `ssh -t` is a session on the multiplexed master. Past ten the
  master answers `mux_client_request_session: session request failed: Session open refused by
  peer`, and ssh *silently* falls back to a brand-new connection — a full handshake, ~5 s extra
  on the work link (measured: 11 concurrent `sleep 4` → 9 took 4.6 s, 2 were refused and took
  10.1 s). Slower commands overlap more, so it snowballs: after sending a prompt (the send, chat
  polls every second, status reads) a window switch's `select-window` waited ~30 s.
  `RemoteGate` (in `Remote.swift`) now caps each host: background commands share 6 slots,
  **urgent** ones (`run(…, urgent: true)` — switching, sending, keys, tmux actions, uploads) jump
  the queue and may use the rest, and each open terminal takes one slot off the total of 9. New
  user-triggered calls must pass `urgent: true`; new background ones must not. `TmuxDeck
  --check-gate` stress-tests it (20 background `sleep 2` plus one urgent call: urgent returns in
  ~1.1 s against a 0.7 s idle round trip). Commands that wait over 0.5 s or run over 5 s are
  logged under the `perf` category.
- **Commands run on GCD, not the Swift concurrency pool.** `Remote.execute` blocks a thread for
  the whole command (`readDataToEndOfFile`, `waitUntilExit`). Inside `Task.detached` that thread
  belonged to the cooperative pool, which has one thread per core, so a few slow ssh calls
  stalled every other async task in the app.
