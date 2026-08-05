# Recommended extras

None of this is required by the badges. It's terminal hygiene found while
building them, kept separate so the plugin stays one thing. Apply what applies
to you.

## Silence the tab-switch dinging

gpakosz ships `monitor-activity on` with `visual-activity off`, which turns
"activity in another window" into an audible bell. That's a reasonable default
until every window contains a Claude spinner animating constantly, at which
point it dings forever — worst right after switching tabs, because the alert
re-arms for the window you just left.

The badges do everything activity-monitoring was doing here, so it can go:

```tmux
set -g monitor-activity off
set -g bell-action none
```

## The "frozen tmux client"

One terminal window's tmux looks completely dead: no response to tab clicks, no
response to the prefix. A new terminal window attaching to the same session
works fine, which makes it look like a client-specific tmux bug.

It isn't. The frozen client is still *sending* input the whole time — tmux logs
its clicks. Only its output is frozen. Two causes:

**`Ctrl-S`** — XON/XOFF flow control, which freezes terminal output until you
press `Ctrl-Q`. It's one key from `Ctrl-A` if your prefix is remapped there, and
nothing on screen tells you what happened. In `~/.zshrc`, **above** the line
that sources oh-my-zsh:

```zsh
# Disable XON/XOFF flow control: an accidental Ctrl-S freezes the terminal's
# output (looks like a dead tmux client; Ctrl-Q unfreezes). Must run before
# oh-my-zsh, which may exec straight into tmux.
[[ -t 0 ]] && stty -ixon
```

Ordering is not optional. If oh-my-zsh is configured to autostart tmux it execs
straight into it and never reaches anything below that line.

**`prefix + Ctrl-z`** — `suspend-client`. One key off the `C-a C-a` pane-cycling
chord. With no visible job control to resume from, it presents as a dead
terminal:

```tmux
unbind C-z
```

**Recovery**, if a client still freezes: try `Ctrl-Q` in it first. Otherwise,
from a healthy window, `tmux list-clients` shows the stuck tty and
`tmux detach-client -t /dev/ttysNNN` frees it.

## Unrelated: `claude` dying instantly with `killed`

Exit 137 with no output is a macOS code-signature rejection, nothing to do with
tmux. Confirm it, then repair:

```sh
ls -t ~/Library/Logs/DiagnosticReports/claude-*.ips | head -1   # "Taskgated Invalid Signature"
brew reinstall --cask claude-code@latest
```

`codesign --verify` reports "valid on disk" the whole time the kernel is
refusing to load the binary, so it isn't a useful check here. The crash report
is.
