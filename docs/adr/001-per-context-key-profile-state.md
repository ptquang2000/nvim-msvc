# ADR 001: Per-context-key settings state

**Status**: Accepted  
**Date**: 2026-05-24  
**Amended**: 2026-06-20

## Context

The plugin held a single active build configuration for the whole session. A developer working across multiple solutions or toggling between a solution-wide build and a pinned project build had to manually re-apply settings each time they switched — even if they had already configured the right settings for that combination.

## Decision

Introduce a **context key** — the `(solution, project)` pair (either component may be `nil`) — as the unit of settings isolation. On every call to `set_solution()` or `set_project()`:

1. Save the current flat settings table for the outgoing key into `_context_store`.
2. Restore the stored settings for the incoming key, or initialise from `settings` defaults if the key is new.

`_context_store` is an in-memory table; state does not persist across Neovim sessions.

## Consequences

- Switching solutions or pinning/unpinning a project automatically restores the settings last used for that combination — no manual re-selection.
- Settings changes made in the `msvc://` buffer are scoped to the current key and survive round-trips back to that key within the session.
- No disk I/O or serialisation. Per-session memory only.
- ADR 004 changed the stored payload from `{ profile_name, overrides }` to a flat settings table; the save/restore mechanism itself is unchanged.
