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

---

## Hooks are snapshotted at session start, and nothing reloads them

A running session uses the hook configuration that existed when it launched.
**Restarting the `claude` process is the only way to change that.**

Two things that do *not* work, both tested:

- **`/hooks` does not reload.** In 2.1.x it's a read-only viewer — it says so on
  screen: *"This menu is read-only. To add or modify hooks, edit settings.json
  directly."* It also only lists `settings.json` hooks; plugin-provided hooks don't
  appear in it at all.
- **Installing or enabling a plugin does not propagate into live sessions.**

The experiment: disable the plugin, start a session (so it snapshots with no badge
hooks), re-enable the plugin, run a turn — badge doesn't move. Run `/hooks`, run
another turn — still doesn't move. Start a *fresh* session — badge works
immediately.

The tmux window doesn't need touching; only the `claude` process. `claude --resume`
restarts it while keeping the thread.

### The consequence worth knowing

If you change the path a hook points at, sessions already running still invoke the
**old path**. A missing hook script fails **silently** — no error surfaces
anywhere. The badge simply freezes at whatever state it last held. A stuck ❓ that
never resolves after you answer is the tell. See the migration section in the
README.

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
