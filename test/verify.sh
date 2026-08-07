#!/usr/bin/env bash
# Verification suite for tmux-claude-status.
#
# Two rules this suite exists to enforce, both learned by shipping the bug:
#
#  1. Assert on what a tab ACTUALLY RENDERS, for the active tab as well as
#     inactive ones. Checking the @claude_status option value, or only
#     window-status-format, passes green while the selected tab draws nothing —
#     because the selected tab renders from window-status-current-format.
#
#  2. Run against a CLEAN tmux (-f /dev/null). `tmux -L somesocket` still reads
#     ~/.tmux.conf, so without this the suite silently tests your personal
#     config instead of the plugin.
#
#   ./test/verify.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMUX_BIN="${TMUX_BIN:-$(command -v tmux)}"
[ -x "$TMUX_BIN" ] || { echo "tmux not found; set TMUX_BIN=/path/to/tmux" >&2; exit 2; }
SOCK="claude-status-verify-$$"
TM=("$TMUX_BIN" -L "$SOCK" -f /dev/null)      # -f /dev/null = ignore ~/.tmux.conf

pass=0; fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
is() { [ "$2" = "$3" ] && ok "$1" || no "$1 — got [$2] expected [$3]"; }
contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 — [$2] lacks [$3]" ;; esac; }
not_contains() { case "$2" in *"$3"*) no "$1 — [$2] still shows [$3]" ;; *) ok "$1" ;; esac; }
cleanup() { "${TM[@]}" kill-server 2>/dev/null; }
trap cleanup EXIT

"${TM[@]}" new-session -d -s t -n w1 -x 200 -y 50
"${TM[@]}" new-window -d -t t: -n w2
"${TM[@]}" set-hook -g 'session-window-changed[42]' 'display-message hook-before-plugin'
"${TM[@]}" run-shell "$ROOT/claude-status.tmux"
sleep 0.5

GLYPH_running=$("${TM[@]}" show-option -gqv @claude_badge_running)
GLYPH_question=$("${TM[@]}" show-option -gqv @claude_badge_question)
GLYPH_shells=$("${TM[@]}" show-option -gqv @claude_badge_shells)
GLYPH_done=$("${TM[@]}" show-option -gqv @claude_badge_done)
# defaults live in the .tmux script, so read them back off the built fragment
[ -n "$GLYPH_running" ] || { GLYPH_running='🔄'; GLYPH_question='❓'; GLYPH_shells='⏳'; GLYPH_done='✅'; }

draw() {  # what window 1's tab renders right now, honouring active/inactive
  local fmt=window-status-format
  [ "$("${TM[@]}" display-message -p -t t:w1 '#{window_active}')" = 1 ] && fmt=window-status-current-format
  "${TM[@]}" display-message -p -t t:w1 "#{E:$fmt}" | sed 's/#\[[^]]*\]//g'
}
set_state()   { "${TM[@]}" set-option -w -t t:w1 @claude_status "$1"; }
clear_state() { "${TM[@]}" set-option -w -t t:w1 -u @claude_status 2>/dev/null; }
state()       { "${TM[@]}" display-message -p -t t:w1 '#{@claude_status}'; }
enter1() { "${TM[@]}" select-window -t t:w1; sleep 0.3; }
leave1() { "${TM[@]}" select-window -t t:w2; sleep 0.3; }
hook() {
  TMUX="$("${TM[@]}" display-message -p '#{socket_path}'),0,0" \
  TMUX_PANE="$("${TM[@]}" list-panes -t t:w1 -F '#{pane_id}' | head -1)" \
  CLAUDE_STATUS_TMUX_BIN="$TMUX_BIN" "$ROOT/bin/claude-status" "$@" >/dev/null 2>&1
}

echo "== fragment =="
contains "publishes @claude_badge_fmt" "$("${TM[@]}" show-option -gqv @claude_badge_fmt)" '@claude_status'
contains "auto-appended to window-status-format"         "$("${TM[@]}" show-option -gqv window-status-format)"         '@claude_badge_fmt'
contains "auto-appended to window-status-current-format" "$("${TM[@]}" show-option -gqv window-status-current-format)" '@claude_badge_fmt'
"${TM[@]}" set-hook -g 'session-window-changed[43]' 'display-message hook-after-plugin'
"${TM[@]}" run-shell "$ROOT/claude-status.tmux"; sleep 0.4
n=$("${TM[@]}" show-option -gqv window-status-format | grep -o '@claude_badge_fmt' | wc -l | tr -d ' ')
is "re-sourcing does not stack duplicates" "$n" "1"
hooks=$("${TM[@]}" show-hooks -g)
contains "preserves hooks installed before first load" "$hooks" 'session-window-changed[42] display-message hook-before-plugin'
contains "preserves hooks installed before reload"     "$hooks" 'session-window-changed[43] display-message hook-after-plugin'

echo "== renders in BOTH formats (the bug that shipped twice) =="
# Switch windows FIRST, then set the state: "done" clears on both arrive and
# leave, so setting it before a switch means the clear rules correctly wipe it
# before anything is drawn. Position, then set, then read.
for st in running question shells done; do
  eval "g=\$GLYPH_$st"
  leave1; set_state "$st"; contains "$st renders on inactive tab" "$(draw)" "$g"
  enter1; set_state "$st"; contains "$st renders on ACTIVE tab"   "$(draw)" "$g"
  clear_state
done
clear_state; leave1
for st in running question shells done; do
  eval "g=\$GLYPH_$st"
  not_contains "idle shows no $st glyph" "$(draw)" "$g"
done

echo "== clearing rules =="
for st in running question shells; do
  set_state "$st"; enter1; is "$st survives arriving" "$(state)" "$st"
  leave1;                  is "$st survives leaving"  "$(state)" "$st"
  clear_state
done
set_state done; enter1;  is "done clears on arrive" "$(state)" ""
leave1; enter1; set_state done; leave1
is "done clears on leave (it appeared while you were there)" "$(state)" ""

echo "== state machine =="
clear_state; leave1
hook prompt; is "prompt -> running"          "$(state)" running
hook ask;    is "ask -> question"            "$(state)" question
hook busy;   is "busy retires the question"  "$(state)" running
set_state shells; hook busy
is "busy leaves shells alone" "$(state)" shells
hook end;    is "end clears" "$(state)" ""

echo "== safety =="
env -u TMUX -u TMUX_PANE "$ROOT/bin/claude-status" stop >/dev/null 2>&1
is "no-ops cleanly outside tmux" "$?" "0"
"$ROOT/bin/claude-status" bogus-arg >/dev/null 2>&1
is "rejects unknown args" "$?" "2"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ] || exit 1
