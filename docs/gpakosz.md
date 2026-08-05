# Using this with gpakosz "Oh my tmux!"

gpakosz owns the status line. It sources `~/.tmux.conf.local` early, then
rebuilds `window-status-format` and `window-status-current-format` from its own
`tmux_conf_theme_*` variables afterwards. Anything that sets those tmux options
directly — including this plugin's auto-append — gets overwritten.

So under gpakosz you splice the fragment into its variables instead.

## 1. Turn off auto-append and load the renderer

In `~/.tmux.conf.local`, under "user customizations":

```tmux
set -g @claude_badge_auto_append off
run-shell ~/path/to/tmux-claude-status/claude-status.tmux
```

## 2. Add the fragment to BOTH format variables

In the "window status style" and "window current status style" sections:

```diff
-tmux_conf_theme_window_status_format='#I #W'
+tmux_conf_theme_window_status_format='#I #W#{E:@claude_badge_fmt}'

-tmux_conf_theme_window_status_current_format='#I #W'
+tmux_conf_theme_window_status_current_format='#I #W#{E:@claude_badge_fmt}'
```

**Both lines are required.** The selected tab renders from `_current_format`.
Change only the first and every badge disappears the instant you click into that
tab, and comes back when you click away — which looks like the badges are
broken rather than like a missing format string.

## 3. Reload

```sh
tmux source-file ~/.tmux.conf     # or prefix + r
```

## Optional: the toggle key

gpakosz leaves `B` free:

```tmux
set -g @claude_badge_toggle_key 'B'
```

`prefix + B` then flips ✅ between clearing on visit and persisting until your
next prompt, and tells you which mode you're in.

## Gotcha: `prefix + r` fails with `returned 127`

Not caused by this plugin, but it will happen eventually and it looks like your
new config broke something. gpakosz caches `TMUX_PROGRAM` as a versioned
Homebrew Cellar path, which a tmux upgrade deletes:

```sh
tmux set-environment -g TMUX_PROGRAM /opt/homebrew/bin/tmux
tmux source-file ~/.tmux.conf
```

This recurs on every Homebrew tmux upgrade, so it's worth a standing health
check rather than rediscovering it twice a year.
