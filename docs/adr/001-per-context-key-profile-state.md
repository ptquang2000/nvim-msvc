# ADR 001: Per-context-key profile state

**Status**: Accepted  
**Date**: 2026-05-24

## Context

The plugin holds a single active `profile_name` and `overrides` table for the whole session. A developer working across multiple solutions or toggling between a solution-wide build and a pinned project build must manually re-select the profile and re-apply overrides each time they switch — even if they have already configured the right settings for that combination.

## Decision

Introduce a **context key** — the `(solution, project)` pair (either component may be `nil`) — as the unit of profile isolation. On every call to `set_solution()` or `set_project()`:

1. Save `{ profile_name, overrides }` for the outgoing key into `_context_store`.
2. Restore the stored state for the incoming key, or initialise from `settings.default_profile` + empty overrides if the key is new.

`_context_store` is an in-memory table; state does not persist across Neovim sessions.

## Consequences

- Switching solutions or pinning/unpinning a project automatically restores the profile state last used for that combination — no manual re-selection.
- `:Msvc profile <name>` and `:Msvc update` still work exactly as before; their effects are now scoped to the current key and survive round-trips back to that key within the session.
- `discover_solution()` (startup path and `:Msvc discover`) sets `self.solution` directly without going through `set_solution()`, so it does not participate in context save/restore. This is intentional: discover is a scan operation, not a deliberate context switch.
- No disk I/O or serialisation. Per-session memory only.
