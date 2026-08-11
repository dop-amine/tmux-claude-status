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
LEGACY_TM=("$TMUX_BIN" -L "$SOCK-legacy" -f /dev/null)

pass=0; fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
is() { [ "$2" = "$3" ] && ok "$1" || no "$1 — got [$2] expected [$3]"; }
contains()     { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 — [$2] lacks [$3]" ;; esac; }
not_contains() { case "$2" in *"$3"*) no "$1 — [$2] still shows [$3]" ;; *) ok "$1" ;; esac; }
cleanup() {
  "${TM[@]}" kill-server 2>/dev/null
  "${LEGACY_TM[@]}" kill-server 2>/dev/null
}
trap cleanup EXIT

"${TM[@]}" new-session -d -s t -n w1 -x 200 -y 50
"${TM[@]}" new-window -d -t t: -n w2
"${TM[@]}" set-hook -g 'session-window-changed[42]' 'display-message hook-before-plugin'
"${TM[@]}" set-hook -g 'session-window-changed[90100]' 'display-message occupied-slot-90100'
"${TM[@]}" set-hook -g 'session-window-changed[90101]' 'display-message occupied-slot-90101'
"${TM[@]}" run-shell "$ROOT/claude-status.tmux"
sleep 0.5

GLYPH_running=$("${TM[@]}" show-option -gqv @claude_badge_running)
GLYPH_question=$("${TM[@]}" show-option -gqv @claude_badge_question)
GLYPH_plan=$("${TM[@]}" show-option -gqv @claude_badge_plan)
GLYPH_error=$("${TM[@]}" show-option -gqv @claude_badge_error)
GLYPH_loop=$("${TM[@]}" show-option -gqv @claude_badge_loop)
GLYPH_shells=$("${TM[@]}" show-option -gqv @claude_badge_shells)
GLYPH_done=$("${TM[@]}" show-option -gqv @claude_badge_done)
# defaults live in the .tmux script, so read them back off the built fragment
[ -n "$GLYPH_running" ] || { GLYPH_running='🔄'; GLYPH_question='❓'; GLYPH_plan='📝'; GLYPH_error='⚠️'; GLYPH_loop='🌀'; GLYPH_shells='⏳'; GLYPH_done='✅'; }

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
contains "preserves occupied hook slot 90100" "$hooks" 'session-window-changed[90100] display-message occupied-slot-90100'
contains "preserves occupied hook slot 90101" "$hooks" 'session-window-changed[90101] display-message occupied-slot-90101'
current_hooks=$(printf '%s\n' "$hooks" | grep -F 'set-option -w -u @claude_status' | wc -l | tr -d ' ')
previous_hooks=$(printf '%s\n' "$hooks" | grep -F 'set-option -w -t ! -u @claude_status' | wc -l | tr -d ' ')
is "registers one current-window clear hook"  "$current_hooks" "1"
is "registers one previous-window clear hook" "$previous_hooks" "1"

echo "== live upgrade from legacy hook slots =="
"${LEGACY_TM[@]}" new-session -d -s legacy -n w1 -x 200 -y 50
legacy_cond='#{&&:#{@claude_badge_clear_on_visit},#{==:#{@claude_status},done}}'
"${LEGACY_TM[@]}" set-hook -g 'session-window-changed[0]' \
  "if -F \"$legacy_cond\" 'set-option -w -u @claude_status'"
"${LEGACY_TM[@]}" set-hook -g 'session-window-changed[1]' \
  "if -F -t '!' \"$legacy_cond\" 'set-option -w -t ! -u @claude_status'"
"${LEGACY_TM[@]}" run-shell "$ROOT/claude-status.tmux"; sleep 0.4
legacy_hooks=$("${LEGACY_TM[@]}" show-hooks -g)
legacy_current=$(printf '%s\n' "$legacy_hooks" | grep -F 'set-option -w -u @claude_status' | wc -l | tr -d ' ')
legacy_previous=$(printf '%s\n' "$legacy_hooks" | grep -F 'set-option -w -t ! -u @claude_status' | wc -l | tr -d ' ')
is "does not duplicate the legacy current hook"  "$legacy_current" "1"
is "does not duplicate the legacy previous hook" "$legacy_previous" "1"
# #16: legacy handlers predate @claude_ack, so keeping them verbatim would leave
# the multi-pane suppression dormant on any server upgraded in place.
legacy_ack=$(printf '%s\n' "$legacy_hooks" | grep -c '@claude_ack')
is "legacy handlers are upgraded to write @claude_ack" "$legacy_ack" "2"
"${LEGACY_TM[@]}" set-hook -g 'session-window-changed[7]' 'display-message unrelated'
"${LEGACY_TM[@]}" run-shell "$ROOT/claude-status.tmux"; sleep 0.4
contains "upgrading preserves unrelated hooks" \
  "$("${LEGACY_TM[@]}" show-hooks -g)" 'session-window-changed[7] display-message unrelated'
again=$("${LEGACY_TM[@]}" show-hooks -g | grep -Fc 'set-option -w -u @claude_status')
is "upgrading twice still leaves one current handler" "$again" "1"

echo "== renders in BOTH formats (the bug that shipped twice) =="
# Switch windows FIRST, then set the state: "done" clears on both arrive and
# leave, so setting it before a switch means the clear rules correctly wipe it
# before anything is drawn. Position, then set, then read.
for st in running question plan error shells loop done; do
  eval "g=\$GLYPH_$st"
  leave1; set_state "$st"; contains "$st renders on inactive tab" "$(draw)" "$g"
  enter1; set_state "$st"; contains "$st renders on ACTIVE tab"   "$(draw)" "$g"
  clear_state
done
clear_state; leave1
for st in running question plan error shells loop done; do
  eval "g=\$GLYPH_$st"
  not_contains "idle shows no $st glyph" "$(draw)" "$g"
done

echo "== clearing rules =="
for st in running question plan error shells loop; do
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

echo "== commas in custom badge values (#8) =="
CSOCK="claude-status-comma-$$"
CTM=("$TMUX_BIN" -L "$CSOCK" -f /dev/null)
"${CTM[@]}" new-session -d -s c -n w1
"${CTM[@]}" set -g @claude_badge_done '#[fg=red,bg=black]Q'
"${CTM[@]}" run-shell "$ROOT/claude-status.tmux"; sleep 0.4
"${CTM[@]}" set -w -t c:w1 @claude_status done
contains "multi-attribute style survives the conditional" \
  "$("${CTM[@]}" display-message -p -t c:w1 '#{E:window-status-format}')" '#[fg=red,bg=black]Q'
"${CTM[@]}" kill-server 2>/dev/null

echo "== stop and background-shell detection (#3) =="
# Build a real process tree. Copies of system binaries won't execute on macOS
# (the copy fails signature validation), but a symlink does — and ps reports the
# symlink's own path, which is what the name filter matches on.
FAKE=$(mktemp -d)
ln -s /bin/sleep "$FAKE/claude"; ln -s /bin/sh "$FAKE/sh_claude"; ln -s /bin/sh "$FAKE/zsh"
"${TM[@]}" new-window -d -t t: -n proc "$FAKE/claude 30"
sleep 1
PROCPANE=$("${TM[@]}" list-panes -t t:proc -F '#{pane_id}')
runhook() { TMUX="$("${TM[@]}" display-message -p '#{socket_path}'),0,0" TMUX_PANE="$1" \
            CLAUDE_STATUS_TMUX_BIN="$TMUX_BIN" "$ROOT/bin/claude-status" "$2" >/dev/null 2>&1; }
runhook "$PROCPANE" stop
is "stop with no shell children -> done" \
  "$("${TM[@]}" display-message -p -t "$PROCPANE" '#{@claude_pane_status}')" "done"
"${TM[@]}" kill-window -t t:proc 2>/dev/null

# claude with a real shell child of its own. The child must be a descendant of
# the fake claude, not of this script, or bg_shell_count correctly ignores it.
# The trailing ';:' stops sh exec'ing away and leaving no shell process behind.
"${TM[@]}" new-window -d -t t: -n proc2 "$FAKE/sh_claude -c '$FAKE/zsh -c \"sleep 30; :\" & sleep 30'"
sleep 1.5
PROCPANE2=$("${TM[@]}" list-panes -t t:proc2 -F '#{pane_id}')
CLAUDEPID=$("${TM[@]}" display-message -p -t "$PROCPANE2" '#{pane_pid}')
is "harness built a claude process" "$(ps -o comm= -p "$CLAUDEPID" | sed 's|.*/||')" "sh_claude"
kids=$(ps -eo ppid,comm | awk -v c="$CLAUDEPID" '$1==c' | grep -c 'zsh')
is "harness gave it a shell child" "$kids" "1"
runhook "$PROCPANE2" stop
is "stop with a live shell child -> shells" \
  "$("${TM[@]}" display-message -p -t "$PROCPANE2" '#{@claude_pane_status}')" "shells"
"${TM[@]}" kill-window -t t:proc2 2>/dev/null
rm -rf "$FAKE"

# a pane with no claude process at all must not crash or report shells
runhook "$(${TM[@]} list-panes -t t:w2 -F '#{pane_id}')" stop
is "stop with no claude process -> done" \
  "$("${TM[@]}" display-message -p -t t:w2 '#{@claude_pane_status}')" "done"
runhook "$(${TM[@]} list-panes -t t:w2 -F '#{pane_id}')" end

echo "== background agents (#7) =="
AP=$("${TM[@]}" list-panes -t t:w1 -F '#{pane_id}' | head -1)
runhook "$AP" end
runhook "$AP" agent-start
runhook "$AP" stop
is "an agent with no shells still reports shells" \
  "$("${TM[@]}" display-message -p -t "$AP" '#{@claude_pane_status}')" "shells"
runhook "$AP" agent-stop
is "last agent finishing promotes to done" \
  "$("${TM[@]}" display-message -p -t "$AP" '#{@claude_pane_status}')" "done"
runhook "$AP" agent-start; runhook "$AP" agent-start; runhook "$AP" agent-stop; runhook "$AP" stop
is "two agents, one finished, still working" \
  "$("${TM[@]}" display-message -p -t "$AP" '#{@claude_pane_status}')" "shells"
runhook "$AP" start
is "SessionStart resets a stuck agent count" "$("${TM[@]}" display-message -p -t "$AP" '#{@claude_agents}')" "0"

echo "== multiple panes in one window (#4) =="
"${TM[@]}" new-window -d -t t: -n multi
"${TM[@]}" split-window -t t:multi
MP1=$("${TM[@]}" list-panes -t t:multi -F '#{pane_id}' | head -1)
MP2=$("${TM[@]}" list-panes -t t:multi -F '#{pane_id}' | tail -1)
runhook "$MP1" prompt; runhook "$MP2" stop
is "pane states are independent (pane 1)" "$("${TM[@]}" display-message -p -t "$MP1" '#{@claude_pane_status}')" "running"
is "pane states are independent (pane 2)" "$("${TM[@]}" display-message -p -t "$MP2" '#{@claude_pane_status}')" "done"
is "window shows the most urgent (done beats running)" \
  "$("${TM[@]}" display-message -p -t t:multi '#{@claude_status}')" "done"
runhook "$MP1" ask
is "question outranks everything" "$("${TM[@]}" display-message -p -t t:multi '#{@claude_status}')" "question"
runhook "$MP1" end; runhook "$MP2" end
is "clearing every pane clears the window" "$("${TM[@]}" display-message -p -t t:multi '#{@claude_status}')" ""

echo "== stale state recovery (#5) =="
runhook "$MP1" prompt; runhook "$MP2" prompt
runhook "$MP1" start                     # a new session takes over pane 1 only
is "SessionStart repairs its own pane"      "$("${TM[@]}" display-message -p -t "$MP1" '#{@claude_pane_status}')" ""
is "SessionStart leaves a sibling pane alone" "$("${TM[@]}" display-message -p -t "$MP2" '#{@claude_pane_status}')" "running"
runhook "$MP2" end
"${TM[@]}" kill-window -t t:multi 2>/dev/null

echo "== failure events (#10) =="
HJ="$ROOT/claude-plugin/hooks/hooks.json"
for ev in PostToolUseFailure StopFailure SubagentStart SubagentStop SessionStart; do
  contains "hooks.json wires $ev" "$(cat "$HJ")" "\"$ev\""
done


echo "== plan awaiting approval (#15) =="
PP=$("${TM[@]}" list-panes -t t:w1 -F '#{pane_id}' | head -1)
runhook "$PP" end
runhook "$PP" plan
is "ExitPlanMode -> plan" "$("${TM[@]}" display-message -p -t "$PP" '#{@claude_pane_status}')" "plan"
runhook "$PP" busy
is "approving the plan retires it" "$("${TM[@]}" display-message -p -t "$PP" '#{@claude_pane_status}')" "running"
runhook "$PP" plan
"${TM[@]}" select-window -t t:w1; sleep 0.3
is "plan survives arriving" "$("${TM[@]}" display-message -p -t "$PP" '#{@claude_pane_status}')" "plan"
"${TM[@]}" select-window -t t:w2; sleep 0.3
is "plan survives leaving" "$("${TM[@]}" display-message -p -t "$PP" '#{@claude_pane_status}')" "plan"
runhook "$PP" end
contains "hooks.json matches ExitPlanMode" "$(cat "$ROOT/claude-plugin/hooks/hooks.json")" '"ExitPlanMode"'


echo "== loops and failures (#19) =="
LP=$("${TM[@]}" list-panes -t t:w1 -F '#{pane_id}' | head -1)
hookin() { TMUX="$("${TM[@]}" display-message -p '#{socket_path}'),0,0" TMUX_PANE="$1" \
           CLAUDE_STATUS_TMUX_BIN="$TMUX_BIN" "$ROOT/bin/claude-status" "$2" >/dev/null 2>&1; }
runhook "$LP" end

# dynamic loop: ScheduleWakeup arms it, so the turn ending is not "done"
printf '%s' '{"tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":1200,"prompt":"/drive"}}' | hookin "$LP" loop-arm
runhook "$LP" stop
is "a scheduled wakeup makes stop report loop" "$("${TM[@]}" display-message -p -t "$LP" '#{@claude_pane_status}')" "loop"
printf '%s' '{"tool_name":"ScheduleWakeup","tool_input":{"stop":true}}' | hookin "$LP" loop-arm
runhook "$LP" stop
is "stop:true ends the loop, back to done" "$("${TM[@]}" display-message -p -t "$LP" '#{@claude_pane_status}')" "done"

# interval loop / scheduled job: cron jobs wake this same session
runhook "$LP" end
printf '%s' '{"tool_name":"CronCreate","tool_input":{"cron":"*/5 * * * *","prompt":"/drive"}}' | hookin "$LP" cron-add
runhook "$LP" stop
is "a live cron job makes stop report loop" "$("${TM[@]}" display-message -p -t "$LP" '#{@claude_pane_status}')" "loop"
printf '%s' '{}' | hookin "$LP" cron-add
printf '%s' '{}' | hookin "$LP" cron-del
runhook "$LP" stop
is "one of two crons deleted still loops" "$("${TM[@]}" display-message -p -t "$LP" '#{@claude_pane_status}')" "loop"
printf '%s' '{}' | hookin "$LP" cron-del
runhook "$LP" stop
is "last cron deleted, back to done" "$("${TM[@]}" display-message -p -t "$LP" '#{@claude_pane_status}')" "done"

# real work still outranks a loop
printf '%s' '{"tool_input":{}}' | hookin "$LP" loop-arm
runhook "$LP" agent-start; runhook "$LP" stop
is "running work outranks the loop badge" "$("${TM[@]}" display-message -p -t "$LP" '#{@claude_pane_status}')" "shells"
runhook "$LP" agent-stop

# StopFailure must not look like a finished turn
runhook "$LP" end
runhook "$LP" failed
is "StopFailure reports error, not done" "$("${TM[@]}" display-message -p -t "$LP" '#{@claude_pane_status}')" "error"
runhook "$LP" prompt
is "retrying clears the error" "$("${TM[@]}" display-message -p -t "$LP" '#{@claude_pane_status}')" "running"
runhook "$LP" start
is "SessionStart resets loop bookkeeping" "$("${TM[@]}" display-message -p -t "$LP" '#{@claude_crons}')" "0"
runhook "$LP" end
for m in ScheduleWakeup CronCreate CronDelete StopFailure; do
  contains "hooks.json wires $m" "$(cat "$ROOT/claude-plugin/hooks/hooks.json")" "\"$m\""
done

echo "== safety =="
env -u TMUX -u TMUX_PANE "$ROOT/bin/claude-status" stop >/dev/null 2>&1
is "no-ops cleanly outside tmux" "$?" "0"
"$ROOT/bin/claude-status" bogus-arg >/dev/null 2>&1
is "rejects unknown args (inside or outside tmux)" "$?" "2"
env -u TMUX -u TMUX_PANE "$ROOT/bin/claude-status" bogus-arg >/dev/null 2>&1
is "rejects unknown args with no tmux env" "$?" "2"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ] || exit 1
