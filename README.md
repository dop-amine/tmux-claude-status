# tmux-claude-status

**[dop-amine.github.io/tmux-claude-status](https://dop-amine.github.io/tmux-claude-status/)** · **[write-up](https://dop-amine.com/blog/claude-code-tmux-badges)**

![tmux-claude-status in action](docs/demo.gif)

Per-window tmux tab badges for Claude Code sessions. When you're running several
sessions across tmux windows, the tab bar tells you which one needs you.

```
 ❐ 0   1 api ✅   2 review 🔄   3 docs   4 deploy ⏳   5 infra ❓
              ↑ ready      ↑ working      ↑ shells    ↑ waiting on you
```

| Badge | State | Meaning |
|---|---|---|
| *(none)* | idle | Nothing running, nothing unread |
| 🔄 | `running` | Prompt in flight, Claude is working |
| ❓ | `question` | Blocked on you — permission prompt, AskUserQuestion, MCP dialog |
| ⏳ | `shells` | Turn finished, but background shells it started are still running |
| ✅ | `done` | Turn finished, nothing running, ready to read |

**Only ✅ ever clears.** 🔄 / ❓ / ⏳ describe live state, and looking at a window
doesn't answer a question or finish a build. ✅ clears when you arrive at the
window, and also when you *leave* a window it appeared in — because that's the
point at which you've genuinely had your chance to read it.

## How it's put together

Two halves that don't know about each other, joined by one tmux option:

- **State** — `bin/claude-status`, driven by Claude Code hooks. It sets
  `@claude_status` on the window owning `$TMUX_PANE` and nothing else.
- **Render** — `claude-status.tmux` builds a format fragment from that option
  and publishes it as `@claude_badge_fmt`.

That split is deliberate: anything that can read a tmux option can render the
badge, and the state half works unchanged if you swap the renderer.

## Install

### 1. The renderer

**TPM:**

```tmux
set -g @plugin 'dop-amine/tmux-claude-status'
```

**Manual:**

```tmux
run-shell ~/path/to/tmux-claude-status/claude-status.tmux
```

By default it appends the badge to `window-status-format` **and**
`window-status-current-format`. Both matter: the selected tab renders from the
`current` one, so setting only the first makes every badge vanish the moment you
click into that tab.

Using gpakosz "Oh my tmux!"? See **[docs/gpakosz.md](docs/gpakosz.md)** — it
rebuilds the formats after sourcing your overrides, so auto-append can't work
there and you splice the fragment in yourself.

### 2. The hooks

**As a Claude Code plugin** (no JSON editing, no absolute paths):

```
/plugin marketplace add /path/to/tmux-claude-status
/plugin install tmux-claude-status@tmux-claude-status
```

**Or by hand** in `~/.claude/settings.json`, substituting your real path:

```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/path/to/bin/claude-status prompt" }] }],
  "Notification":     [{ "matcher": "permission_prompt|elicitation_dialog|agent_needs_input",
                         "hooks": [{ "type": "command", "command": "/path/to/bin/claude-status ask" }] }],
  "PreToolUse":       [{ "matcher": "AskUserQuestion",
                         "hooks": [{ "type": "command", "command": "/path/to/bin/claude-status ask" }] }],
  "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "/path/to/bin/claude-status busy" }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "/path/to/bin/claude-status stop" }] }],
  "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "/path/to/bin/claude-status end" }] }]
}
```

Then reload tmux (`tmux source-file ~/.tmux.conf`) and **restart your Claude Code
sessions**. Hooks are snapshotted at session start, and a restart is the only
way a running session gets them:

- `/hooks` does **not** reload. As of Claude Code 2.1.x it's a read-only viewer
  ("To add or modify hooks, edit settings.json directly").
- Enabling or installing the plugin does **not** propagate into running
  sessions either.

Both verified by starting a session with the plugin disabled, re-enabling it,
running `/hooks`, and confirming the badge still never moved. `claude --resume`
restarts the process while keeping the thread, so a restart costs nothing.

## Migrating from a hand-wired setup

If you previously wired these hooks into `settings.json` by hand and are now
switching to the plugin, **leave the old script path in place until every
running session has been restarted.**

Hooks are snapshotted when a session starts. Sessions already running still hold
the old absolute path, so deleting that file makes every hook invocation fail
silently — badges freeze at whatever state they were in, and nothing tells you.
A stuck ❓ that never resolves after you answer is the tell.

Keep a symlink at the old location until those sessions are gone:

```sh
ln -sfn /path/to/tmux-claude-status/bin/claude-status ~/.claude/hooks/tmux-claude-status.sh
```

The script accepts the older argument names (`clear`, `done`, `unset`) as
aliases for exactly this reason, so sessions snapshotted at any point still
drive the state machine correctly.

## Configuration

All optional. Set before the plugin loads.

| Option | Default | Purpose |
|---|---|---|
| `@claude_badge_running` | `' 🔄 '` | Glyph for each state. Trailing spaces are load-bearing — emoji are double-width and a powerline separator will clip them. |
| `@claude_badge_question` | `' ❓ '` | |
| `@claude_badge_shells` | `' ⏳ '` | |
| `@claude_badge_done` | `' ✅ '` | |
| `@claude_badge_auto_append` | `on` | Append the fragment to both window status formats. Set `off` to splice `#{E:@claude_badge_fmt}` yourself. |
| `@claude_badge_clear_on_visit` | `1` | `0` makes ✅ persist until your next prompt instead. |
| `@claude_badge_toggle_key` | *(unset)* | Bind a prefix key to flip the ✅ lifecycle at runtime, e.g. `B`. |

Single-width glyphs, if emoji clip in your terminal:

```tmux
set -g @claude_badge_done ' #[fg=#27ba09]✔#[none] '
```

## Verify

```sh
./test/verify.sh
```

Runs against an isolated tmux server with `-f /dev/null`, so it tests the plugin
rather than your personal config. It asserts on what a tab **actually renders**,
active and inactive — both rules exist because violating them is how this
project shipped bugs that passed a green test.

Manual smoke test:

```sh
tmux set-option -w -t :1 @claude_status question   # ❓ appears on window 1
tmux set-option -w -t :1 -u @claude_status         # gone
```

## Dogfooding notes

Verified with **no badge hooks in `settings.json` at all** — everything driven by the plugin:

- 🔄 → ⏳ → ✅ across a real background shell
- 🔄 → ❓ → 🔄 → ✅ through a real `AskUserQuestion` dialog, which also proves
  plugin `hooks.json` honours the `matcher` field that ❓ depends on

## Requirements

- tmux ≥ 3.1 (needs the `#{==:}` and `#{&&:}` format operators)
- Claude Code ≥ 2.1.x
- A font that renders your chosen glyphs

## Notes and known edges

- **Why `Notification` is matched, not taken wholesale.** It carries a
  `notification_type`; only `permission_prompt`, `elicitation_dialog` and
  `agent_needs_input` mean "blocked on the user". `idle_prompt` means Claude is
  merely idle, and wiring it would put ❓ on every finished window.
- **Why `session-window-changed` and not `after-select-window`.** The latter is
  a *command* hook that fires only for a literal `select-window`. Clicking a tab
  in the status bar runs `switch-client -t =`, so badges silently never cleared.
- **Why `ps` and not `pgrep`.** `pgrep -P` returns nothing from inside the
  hook's sandboxed execution context — silently, which reads exactly like "no
  background shells".
- A raw disowned `cmd &` isn't tracked by Claude Code, so nothing wakes the
  session when it exits and its ⏳ waits for whatever you do next in that window.
- `PostToolUse` is a catch-all, so a tool completing in parallel with an open
  question could in principle flip ❓ back to 🔄 early. Not observed in practice,
  since `AskUserQuestion` blocks the turn.

## Further reading

- **[docs/hook-contract.md](docs/hook-contract.md)** — the Claude Code hook behaviour
  this depends on, most of which isn't documented anywhere. Written down so it can be
  re-verified when Claude Code changes.
- **[docs/gpakosz.md](docs/gpakosz.md)** — setup for "Oh my tmux!" users.
- **[docs/extras.md](docs/extras.md)** — unrelated terminal fixes found while building
  this: bell silencing, and two ways a tmux client appears frozen.

## Author

Built by Amine — [dop-amine.com](https://dop-amine.com)

The full story of building it, including three bugs that each passed a green test,
is written up at [dop-amine.com/blog/claude-code-tmux-badges](https://dop-amine.com/blog/claude-code-tmux-badges).

MIT licensed. Issues and PRs welcome.
