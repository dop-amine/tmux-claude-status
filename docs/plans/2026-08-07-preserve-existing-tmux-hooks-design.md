# Preserve existing tmux hooks

## Problem

The renderer currently unsets the complete global `session-window-changed` hook
array before registering its own handlers. tmux hook arrays are shared by every
plugin and user configuration in the server. Loading or reloading this plugin
therefore removes unrelated handlers.

## Design

Inspect the registered hooks for the current-window and previous-window clear
actions. Append either handler only when that exact condition and action are
absent. tmux chooses unused array indices when appending, so the plugin never
replaces an occupied slot. Keep the two handlers separate to preserve the
existing commands and targeting behavior.

Detection is independent of array indices. It recognizes handlers installed by
the previous release at indices 0 and 1, so a live upgrade does not leave legacy
duplicates. It also recognizes handlers appended by this release, making config
reloads idempotent. The match includes the event name, clear-on-visit condition,
done-state comparison, and clear action so an unrelated hook does not suppress
registration.

## Verification

Extend the isolated tmux test to install marker hooks before and after the first
renderer load, including markers in the fixed slots rejected during adversarial
review. Source the renderer twice, then assert that all markers remain and that
exactly one copy of each Claude handler is registered. The existing clearing
tests continue to prove that both handlers run.
