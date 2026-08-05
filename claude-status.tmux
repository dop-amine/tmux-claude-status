#!/usr/bin/env bash
# tmux-claude-status — the RENDER half.
#
# TPM entry point (`set -g @plugin 'dop-amine/tmux-claude-status'`), and also
# safe to call directly:  run-shell ~/path/to/claude-status.tmux
#
# What it does:
#   1. builds a badge format fragment and publishes it as @claude_badge_fmt
#   2. optionally appends that fragment to your window status formats
#   3. installs the hooks that clear the ✅ state
#   4. optionally binds a key to toggle the ✅ lifecycle
#
# It deliberately does NOT own your status line. The fragment is exposed so you
# can splice it wherever you want with #{E:@claude_badge_fmt} — which is the
# only workable integration for frameworks that render the status bar
# themselves (see docs/gpakosz.md).
set -euo pipefail

opt() {  # opt <name> <default>
  local v; v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}

# --- appearance -------------------------------------------------------------
# Trailing spaces are load-bearing for emoji: they're double-width and tmux and
# your terminal can disagree by a cell, which lets a powerline separator clip
# the glyph. Override with single-width glyphs if yours still clips, e.g.
#   set -g @claude_badge_done ' #[fg=#27ba09]✔#[none]'
RUNNING="$(opt @claude_badge_running  ' 🔄 ')"
QUESTION="$(opt @claude_badge_question ' ❓ ')"
SHELLS="$(opt @claude_badge_shells   ' ⏳ ')"
DONE="$(opt @claude_badge_done      ' ✅ ')"

FMT="#{?#{==:#{@claude_status},running},${RUNNING},"
FMT+="#{?#{==:#{@claude_status},question},${QUESTION},"
FMT+="#{?#{==:#{@claude_status},shells},${SHELLS},"
FMT+="#{?#{==:#{@claude_status},done},${DONE},}}}}"
tmux set -g @claude_badge_fmt "$FMT"

# --- optional auto-append ---------------------------------------------------
# Convenience for vanilla tmux and most themes. Turn off if you splice the
# fragment yourself, or if your framework rebuilds the formats after this runs
# (gpakosz does — see docs/gpakosz.md).
if [ "$(opt @claude_badge_auto_append on)" = "on" ]; then
  for o in window-status-format window-status-current-format; do
    cur="$(tmux show-option -gqv "$o" 2>/dev/null || true)"
    [ -n "$cur" ] || cur='#I:#W'
    # Idempotent, and guards against double badges two ways: re-sourcing your
    # config must not stack copies of the fragment, and a format that already
    # references @claude_status (spliced by hand, or by a framework like
    # gpakosz) must not get a second badge appended.
    case "$cur" in
      *'@claude_badge_fmt'*|*'@claude_status'*) ;;
      *) tmux set -g "$o" "${cur}#{E:@claude_badge_fmt}" ;;
    esac
  done
fi

# --- clearing ---------------------------------------------------------------
# Only "done" ever clears. running/question/shells describe live state, and
# looking at a window doesn't answer a question or finish a build.
#
# This MUST be session-window-changed, an EVENT hook that fires on any window
# change. after-select-window is a COMMAND hook: it fires only for the literal
# select-window command, and clicking a tab in the status bar runs
# `switch-client -t =`, so badges would silently never clear.
#
# Two clears per change, because ✅ can appear either while you're away or while
# you're sitting in the window:
#   current window — you just arrived, so a waiting ✅ has been seen
#   previous ('!') — it turned ✅ while you were there and you've now left
tmux set -gq @claude_badge_clear_on_visit "$(opt @claude_badge_clear_on_visit 1)"
COND='#{&&:#{@claude_badge_clear_on_visit},#{==:#{@claude_status},done}}'
tmux set-hook -gu session-window-changed 2>/dev/null || true
tmux set-hook -g  session-window-changed "if -F \"$COND\" 'set-option -w -u @claude_status'"
tmux set-hook -ga session-window-changed "if -F -t '!' \"$COND\" 'set-option -w -t ! -u @claude_status'"

# --- optional toggle key ----------------------------------------------------
# Flips the ✅ lifecycle at runtime: clear-on-visit (default) vs persist until
# your next prompt. Reading the option inside the hook is what makes this live —
# a bare set-hook can't be switched off without re-sourcing the config.
KEY="$(opt @claude_badge_toggle_key '')"
if [ -n "$KEY" ]; then
  tmux bind "$KEY" if -F '#{@claude_badge_clear_on_visit}' \
    'set -g @claude_badge_clear_on_visit 0 ; display-message "Claude badge: ✅ persists until next prompt"' \
    'set -g @claude_badge_clear_on_visit 1 ; display-message "Claude badge: ✅ clears when you visit the tab"'
fi
