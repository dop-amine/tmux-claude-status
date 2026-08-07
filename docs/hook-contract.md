# The Claude Code hook contract this depends on

Most of what follows isn't in the public docs. It was found by reading strings out
of the `claude` binary and by running controlled experiments, then confirmed
behaviourally. It's written down here so that when a Claude Code release changes
something, you can tell *what* changed instead of guessing why badges stopped
moving.

Verified against **Claude Code 2.1.x** (macOS arm64 and Linux x86_64).

Everything below is re-checkable. Where a claim came from an experiment, the
experiment is described.

---

## Hook events used

| Event | Arg passed | Purpose |
|---|---|---|
| `UserPromptSubmit` | `prompt` | A turn started |
| `Notification` | `ask` | Blocked on the user |
| `PreToolUse` | `ask` | An `AskUserQuestion` picker is opening |
| `PostToolUse` | `busy` | A tool completed, so a pending question was answered |
| `Stop` | `stop` | Turn finished |
| `SessionEnd` | `end` | Session gone |

The full set of events the binary knows about: `PreToolUse`, `PostToolUse`,
`Notification`, `UserPromptSubmit`, `Stop`, `SubagentStop`, `SessionStart`,
`SessionEnd`, `PreCompact`.

```sh
strings "$(readlink -f "$(command -v claude)")" \
  | grep -xE 'SessionEnd|SessionStart|Stop|SubagentStop|UserPromptSubmit|PreCompact|Notification|PreToolUse|PostToolUse' \
  | sort -u
```

---

## `Notification` carries a `notification_type`, and it must be matched

The payload is `{hook_event_name, message, title?, notification_type}`. The matcher
field for this event is `notification_type`, and its full value set is:

```
permission_prompt    idle_prompt        auth_success
elicitation_dialog   elicitation_complete   elicitation_response
agent_needs_input    agent_completed
```

Only three mean *blocked on the user*: `permission_prompt`, `elicitation_dialog`,
`agent_needs_input`.

**`idle_prompt` is deliberately excluded.** It fires when Claude has simply been
idle for a while, not when it's asking you something. Wiring it would put a ❓ on
every window that had merely finished, which is what ✅ already means.

To re-derive the list:

```sh
strings "$(readlink -f "$(command -v claude)")" \
  | grep -o 'matcherMetadata:{fieldToMatch:"notification_type",values:\[[^]]*\]'
```

---

## Plugin `hooks.json` honours `matcher`

This is load-bearing and was undocumented. Both the `AskUserQuestion` matcher on
`PreToolUse` and the `notification_type` matcher on `Notification` work when
declared in a plugin's `hooks/hooks.json`, not just in `settings.json`.

Verified by installing this plugin as the *only* source of hooks — `settings.json`
carrying none — and driving a real `AskUserQuestion` dialog. The badge went
🔄 → ❓ → 🔄 → ✅. If the matcher were ignored, `PreToolUse` would have fired on
every tool call and ❓ would have been permanently stuck on.

`${CLAUDE_PLUGIN_ROOT}` expands inside hook commands, which is what lets a plugin
ship its own executable without absolute paths.

One more piece of load-bearing installer behaviour: this repo's
`claude-plugin/bin` is a **symlink** to `../bin`, whose target sits *outside*
the plugin source directory. The installer dereferences it when copying into
the plugin cache — the installed `bin/claude-status` is a real executable
file, not a dangling link (verified on 2.1.220 by inspecting the cache and
executing it). If a Claude Code release ever starts copying symlinks
literally, the plugin's hooks will all silently fail; checking that cache file
is the first diagnostic.

---

## Hook reloading: settings hooks are live, plugin hooks are not

Earlier revisions of this document claimed hooks were snapshotted at session
start with nothing able to reload them. That's **half wrong**, and the half
that's wrong was corrected by a stronger experiment. Verified on **2.1.220**:

- **`settings.json` hooks hot-reload into running sessions.** Additions and
  removals both take effect on the session's next turn, no restart.

  The experiment (the part that must be *behavioural* — see the trap below):
  start a fresh session, then append a marker hook to `settings.json`
  (`Stop` → `touch /tmp/proof`), then drive one trivial turn in that
  already-running session. The marker file appears. Removal verified the same
  way in reverse: strip hooks from `settings.json` and a running session's
  `/hooks` count drops — and more importantly, the removed hooks stop firing.

- **Installing or enabling a plugin does not propagate into live sessions.**
  This half of the original claim stands. A session started before
  `plugin install` never fires the plugin's hooks, even after the plugin shows
  enabled and inventoried (`claude plugin details` listing all six). Restart
  the process — `claude --resume` keeps the thread.

- **Plugin hooks register asynchronously at session start.** In a brand-new
  session, a prompt submitted within the first few seconds can complete
  without the plugin's hooks firing at all; the same session badges correctly
  from the next turn on. A fresh session left to settle for ~30s badges
  correctly on its *first* turn. If you're scripting a smoke test, don't fire
  the first prompt instantly after launch.

### The `/hooks` trap

`/hooks` is a read-only viewer that **re-reads `settings.json` live**, and it
doesn't list plugin hooks at all. Both properties make it useless as evidence
of what a running session is executing: it can show hooks the executor also
has (settings, which hot-reload) and it will never show hooks the executor
definitely has (plugin). Conclusions about hook behaviour must come from
watching hooks *fire*, not from this menu — an earlier revision of this very
document got the reload claim wrong by trusting viewer-level evidence.

### The consequence worth knowing

A missing hook **script** fails **silently** — no error surfaces anywhere. Any
session still invoking a deleted path freezes badges at whatever state they
last held. A stuck ❓ that never resolves after you answer is the tell. On
2.1.220 the settings hot-reload makes this mostly a non-issue for hand-wired
hooks (removing the entries stops the invocations too), but it still applies
to any snapshotting version, and to moving/renaming the script while entries
still reference it. See the migration section in the README.

---

## `SessionEnd` fires on exit, but the exit may be gated

`SessionEnd` fires reliably on a clean session exit, which is what clears a 🔄 or ⏳
left behind by a session that ended mid-turn.

It does **not** fire while you're still deciding to leave. If background shells are
running, Claude Code first prompts:

```
The following will stop when you exit:
shell · sleep 45
❯ 1. Exit anyway   2. Move to background and exit   3. Stay
```

Until you answer, the session hasn't ended and `SessionEnd` correctly hasn't fired.
This cost two false conclusions during development — a test sent `/exit`, never
answered the prompt, and concluded the hook was broken.

Choosing **"Move to background and exit"** leaves the shells running with no session
to report on them, so that window keeps its ⏳ until you use it again. Arguably
correct: something really is still running.

---

## `PostToolUse` is a catch-all, and that's a deliberate trade

There's no "the user answered" event. What's observable is that answering a
permission prompt or an `AskUserQuestion` is always followed by a tool completing.
So `PostToolUse` retires the ❓ state.

It fires on *every* tool call, so `bin/claude-status busy` bails on its first tmux
read unless a question is actually pending.

Known edge: a tool completing in parallel with an open question could in principle
flip ❓ back to 🔄 early. Not observed in practice — `AskUserQuestion` blocks the
turn — but it's the honest limitation of using a catch-all as a proxy signal.

---

## `pgrep` doesn't work inside a hook; `ps` does

Detecting live background shells means finding shell children of the `claude`
process. The obvious tool, `pgrep -P <pid>`, **returns nothing** when run from
inside a hook's execution context. Not an error — an empty result, which reads
exactly like "no background shells" and produces a badge that's confidently wrong.

Parsing `ps -eo pid,ppid,comm` works reliably in the same context.

Two details in that detection:

- **Filter on shell names.** A session also has MCP servers (`node`, `python`) and
  possibly `caffeinate` as children. Those are long-lived and would pin every window
  to ⏳ forever. Background shells are `zsh`/`bash`/`sh`.
- **Exclude the hook's own shell.** The hook is itself a shell child of `claude`. Without
  walking its own ancestry and skipping itself, it counts itself, and the state
  machine never reaches ✅.

`comm` reports `claude` on both macOS and Linux — the Linux build is a real
executable, not a `node` wrapper, so the same name filter works on both.

---

## Background *agents* have no process to find

`bg_shell_count` walks the process tree, which finds background **shells** and
misses background **agents** entirely — an agent runs inside the `claude`
process, so there is no child to see. A window with an agent working for minutes
reported ✅ "nothing running, ready to read".

There's no field in the `Stop` payload for pending agents, so they're counted
instead: `SubagentStart` increments a per-pane counter, `SubagentStop`
decrements it, and `stop` reports ⏳ while it's above zero. `SessionStart`
resets it, which is what stops a crash mid-agent from stranding the count above
zero forever.

`agent_needs_input` is already in the `Notification` matcher, so an agent that
blocks on a question surfaces as ❓ rather than silently.

## Failure events are separate events

`PostToolUse` does not fire when a tool fails, and `Stop` does not fire when a
turn dies on an API error — those are `PostToolUseFailure` and `StopFailure`.
Wiring only the success events leaves ❓ stuck after a failed tool, and 🔄 stuck
forever after an API error. Both are wired to the same handlers as their
success counterparts.

## Background work resolves itself without polling

When a tracked background shell exits, Claude Code wakes the session for a
completion turn. That fires `Stop` again, the shell count comes back zero, and ⏳
resolves to ✅ on its own. No timer, no watcher process.

Observed live: 🔄 on submit, ⏳ seven seconds later when the turn ended with a
`sleep` still running, then ✅ the moment the sleep exited.

The exception is a raw disowned `cmd &`, which Claude Code doesn't track — nothing
wakes the session when it finishes, so its ⏳ waits for whatever you do next in that
window.

---

## Re-verifying after a Claude Code upgrade

`test/verify.sh` covers the tmux half and the state machine, but it can't prove the
hook events still fire. For that:

1. Start a session in a **background** tmux window (badges are suppressed for
   nothing — but you want to see them appear on an inactive tab).
2. Ask it to run something with `run_in_background: true`, then reply immediately.
   Expect 🔄 → ⏳ → ✅.
3. Ask it to use `AskUserQuestion`. Expect 🔄 → ❓, holding while the dialog is open,
   then → 🔄 → ✅ after answering.

If ❓ stops working but ⏳ still does, suspect the `matcher` contract first.
