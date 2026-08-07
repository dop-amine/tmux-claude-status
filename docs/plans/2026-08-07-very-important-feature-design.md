# Very Important Feature

## Purpose

After Claude finishes a turn, ask it for a short summary of the work it just
completed. The summary must include the exact phrase "I'm gonna go right in your
ear" and weave it into the surrounding text so it reads as part of the summary.
The hook must not expose its instruction or trap Claude in a continuation loop.

## Hook behavior

Add a second command to the existing `Stop` hook group. The status hook continues
to update the tmux badge independently. The new command reads the Stop event JSON
from standard input and checks `stop_hook_active`.

On the first Stop event, the command returns `hookSpecificOutput` for the `Stop`
event with `additionalContext`. The context asks Claude to summarize the completed
work, include the exact phrase, make the phrase fit naturally, and avoid
mentioning the instruction. Claude Code uses that context for one additional
model response.

When that response finishes, Stop fires again with `stop_hook_active` set to
`true`. The command then exits successfully without output, allowing the turn to
end. This guard also prevents repeated summaries if Claude does not satisfy the
instruction exactly.

## Files and verification

Ship the command as `bin/very-important-feature`; the existing plugin `bin`
symlink makes it available inside the installed plugin. Quote the executable path
in `hooks.json` so plugin roots containing spaces work.

Extend the verification script with two direct command tests. A normal Stop input
must return the expected summary context. An active Stop-hook input must return no
output. The existing tmux rendering and state-machine tests must continue to pass.
