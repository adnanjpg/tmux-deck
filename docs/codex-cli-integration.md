# Codex CLI integration

Tmux Deck starts Codex with the plain `codex` command in the selected tmux session's working
directory, or in a local plain terminal. It intentionally adds no model, approval, sandbox, or
network flags, so the Codex configuration already present on that machine remains authoritative.

Codex is shown with Tmux Deck's real terminal view. Unlike the Claude chat UI, this does not depend
on private transcript files or screen parsing, and it preserves Codex's interactive TUI, prompts,
slash commands, and session picker.

Codex windows are recognized from their foreground `codex` command and use the Codex icon in the
sidebar. When Tmux Deck restores a saved Codex window, it starts a new interactive Codex session in
the saved directory; it does not select or resume a previous Codex conversation automatically.
