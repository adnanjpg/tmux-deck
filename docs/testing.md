# Testing and verifying changes

There are no unit tests. Verification is: build it, install it, run it, look at it. What follows is
the routine that actually catches things, plus the traps that have wasted time or done damage.

## The loop

```bash
swift build                                        # fast syntax/type check while iterating
./build-app.sh                                     # release build + install to ~/Applications
osascript -e 'tell application "Tmux Deck" to quit' # the running copy is the OLD binary
open ~/Applications/"Tmux Deck.app"
```

**Quitting matters.** A rebuild does not touch a running instance. A stale window once ran for two
days across a dozen "shipped" changes, and every report about them was meaningless.
`UpdateWatcher` now shows a Relaunch banner when the installed binary changes, but during your own
testing, quit and reopen explicitly.

If a graceful quit doesn't take (a modal sheet can block it), check with `pgrep -x TmuxDeck` before
assuming the new build is what's on screen.

## Looking at the real window

Full-screen captures include whatever else the user has open. Capture just the app's window:

```bash
# window ids for the app, with sizes; pick the big one
swift - <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Tmux Deck" {
  let b = w[kCGWindowBounds as String] as! [String: Double]
  print(w[kCGWindowNumber as String]!, Int(b["Width"]!), "x", Int(b["Height"]!))
}
EOF

screencapture -x -o -l <windowID> shot.png
sips -Z 1400 shot.png --out shot-small.png      # shrink before reading it
```

The switcher HUD is a separate panel, so capture the whole screen for that one.

## Testing tmux behaviour safely

**Never try tmux commands against the user's real sessions.** Use a throwaway server — it's a
completely separate tmux instance:

```bash
tmux -L decktest new-session -d -s t
tmux -L decktest split-window -h -t t
# … exercise the command you're adding …
tmux -L decktest kill-server
```

This is how `break-pane`, `join-pane`, `swap-window`, `move-window`, zoom and the restore flow were
all validated before being pointed at anything real. Note zsh doesn't word-split `$T="tmux -L x"`;
use a shell function.

For remote behaviour, a throwaway *window* in an existing session is usually enough:

```bash
id=$(ssh host "tmux new-window -d -P -F '#{pane_id}' -t b: bash")
# … test …
ssh host "tmux kill-pane -t $id"
```

## Testing keyboard shortcuts — carefully

Synthetic keystrokes work (System Events needs Accessibility permission, which is granted):

```bash
osascript <<'EOF'
tell application "Tmux Deck" to activate
delay 1.2
tell application "System Events"
    set f to name of first application process whose frontmost is true
    if f is "TmuxDeck" then
        key down control
        key code 48          -- Tab
        delay 2.0
        key up control
    end if
end tell
EOF
```

**The trap:** if focus slips between activating and typing, the keys go to whatever *is* frontmost.
This has switched the user's browser tabs mid-session twice. Check frontmost and send the keys
inside the **same** AppleScript (as above), and don't do it at all when the user is plausibly using
the machine. Prefer reading the code and a static screenshot over driving the keyboard.

## What to check after a change

- The app **launches** and the sidebar populates (servers connect, sessions list).
- A **Claude chat** opens, scrolled to the latest message, and the message box takes a cursor on the
  first click (see `acceptsFirstMouse` in [appkit-and-swiftterm.md](appkit-and-swiftterm.md)).
- **Sending** a message: it appears greyed immediately, then turns normal — meaning delivery was
  confirmed from the transcript, not just assumed.
- If you touched the transcript parser, **bump the cache directory** (`chats-vN` in `ChatStore`),
  otherwise stale caches deserialize into the new shape.
- If you touched anything themed, check it under a **dark** VS Code theme too — hardcoded colours
  only show up there.
- `swift build` with **no warnings**; Swift 6 concurrency warnings become errors later.

## Reporting results honestly

Say what was actually verified and what wasn't. "Built and installed, but I couldn't exercise the
drag-and-drop path" is useful; implying it was tested is not. Screenshots of the real window are the
strongest evidence — use them when the change is visual.
