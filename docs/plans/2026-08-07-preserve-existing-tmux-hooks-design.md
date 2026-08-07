# Preserve existing tmux hooks

## Problem

The renderer currently unsets the complete global `session-window-changed` hook
array before registering its own handlers. tmux hook arrays are shared by every
plugin and user configuration in the server. Loading or reloading this plugin
therefore removes unrelated handlers.

## Design

Register the two Claude badge handlers at dedicated array indices instead of
unsetting the array. Setting an indexed hook replaces only that member, so
reloading remains idempotent while all other indices remain untouched. Keep the
current-window and previous-window handlers separate to preserve the existing
commands and targeting behavior.

Use named shell constants for the selected hook slots. The slots are high enough
to avoid the low indices tmux assigns to appended hooks in normal configurations.
An explicit slot can theoretically conflict with another plugin using the same
number, but that risk is narrower and visible compared with deleting the entire
shared array. Scanning and rewriting hook output would introduce parsing and
quoting risks for no functional benefit.

## Verification

Extend the isolated tmux test to install marker hooks before and after the first
renderer load. Source the renderer twice, then assert that both marker hooks are
still registered. The existing clearing tests continue to prove that the Claude
handlers run for current and previous windows. The existing idempotence check
continues to cover repeated renderer loading.
