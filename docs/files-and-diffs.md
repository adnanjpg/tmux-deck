# Files, diffs and history

Three read-mostly views that sit beside a conversation, all reading the server over the same SSH
connection everything else uses, through small Python programs sent on stdin.

## Files (⇧⌘E) — `Files.swift`, `FileViews.swift`

A tree rooted at the focused window's folder on that window's server. Folders are listed on demand
and cached (`FileTree.children`), so expanding doesn't re-walk anything; the open part of the tree
is flattened into rows, because `OutlineGroup` wants the whole tree up front.

Clicking a file opens it in a tile (`file#<host>#<path>`), so it can sit next to the chat.

### Saving, and not clobbering the agent

An agent is writing to these same files, so the editor is deliberately careful:

- A read returns the file's text **and a sha256 digest**.
- A write sends the digest back; the helper refuses if the file no longer matches it, and the UI
  offers reload or overwrite rather than picking one for you.
- The write goes to `<path>.tmxdeck.tmp` and is renamed over the original, so a dropped connection
  can't truncate a file. The original's mode is preserved.
- Files over 4 MB, files with NUL bytes in the first 8 KB, and non-UTF-8 files are refused with a
  reason rather than mangled.

Syntax highlighting is re-applied on a 400 ms debounce and skipped above 400 000 characters;
colouring on every keystroke is far too slow on a real file.

## Changes (⇧⌘G) — `Diffs.swift`, `DiffView.swift`

**Every session is its own worktree**, so the question is "what does this worktree change against
the branch it lands on", not "what's uncommitted".

- The comparison is the **working tree against the merge base** with the base branch. That covers
  what's been committed on this branch *and* what hasn't, which is what you want when an agent has
  been working in here.
- Untracked files are listed too — a file an agent just wrote is a change whether or not it's staged.
- The base branch comes from `origin/HEAD`, falling back to `dev`, `develop`, `main`, `master`,
  `trunk`, never the current branch. It can be overridden per tile.
- `git worktree list --porcelain` fills a picker, so you can jump between sessions' diffs. (41 of
  them on the machine this was built against.)
- It re-reads every six seconds, because the tree is being written to while you read it.

Tag: `diff#<host>#<path>`.

## Past conversations (⇧⌘O) — `History.swift`, `HistoryView.swift`

Lists what a machine has on disk for both CLIs, newest first:

- Claude Code: `~/.claude/projects/*/<session id>.jsonl`, title from the log's `custom-title` /
  `ai-title` records (a title written late in a long conversation is the one that stuck, so the tail
  is read as well as the head).
- Codex: `~/.codex/sessions/*/*/*/rollout-*.jsonl`, **excluding** threads with a parent — those are
  its subagents and guardian reviews, not conversations. See
  [codex-cli-integration.md](codex-cli-integration.md).

Opening one puts it in a tile read-only (`past#<host>#<assistant>#<id>#<path>`): the same rendering,
with no compose box, no status chips and no polling, because there's no process left to type at.
`ChatView` takes an optional `window` for this; everything that only makes sense for a live session
is behind `if let window`.

Nothing is indexed — titles come from the logs themselves each time the browser is opened.
