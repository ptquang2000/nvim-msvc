# ADR 012: cursor lands on the list title line after collapse

**Status**: Accepted
**Date**: 2026-06-25

## Context

The `msvc://` buffer has two collapsible lists:

- An expanded **settings field** option list (`SETTINGS_FIELD` + its `SETTINGS_OPTION`
  children), toggled with `=` (normal mode).
- An expanded **solution** project list (`SOLUTION` + its `PROJECT` children), toggled with `=`
  (add mode).

ADR 008 made `=` collapse a settings field even when the cursor sits on a child
`SETTINGS_OPTION` line. But neither collapse path repositions the cursor: `render()` rebuilds
the buffer and the cursor keeps its old line number. After a list collapses, the lines below
shift up, so the cursor lands on whatever unrelated line now occupies that row — disorienting,
especially when collapsing from a child line several rows below the title.

## Decision

After `=` collapses a list, move the cursor to that list's **title line** — the
`SETTINGS_FIELD` line for a settings field, or the `SOLUTION` line for a solution — at the
**first non-blank column** (the field/solution name).

This applies regardless of where `=` was pressed:

- On the title line itself → cursor stays on it (re-asserted at first non-blank column).
- On a child `SETTINGS_OPTION` / `PROJECT` line → cursor jumps up to the now-collapsed title.

Mechanic: after the `render(msvc, buf)` that follows a collapse, locate the new buffer line
whose entity is the collapsed `SETTINGS_FIELD` (matching `field`) or `SOLUTION` (matching
`path`), then `nvim_win_set_cursor` to that line at its first non-blank column. Expansion
(opening a list) does not move the cursor — only collapse does.

## Consequences

- Collapsing a list keeps the user anchored on the thing they collapsed, so repeated
  expand/collapse cycles stay in place instead of drifting.
- The collapse handlers in `ui.lua` (`=` keymap) gain a post-render cursor-reposition step for
  the `SETTINGS_FIELD`, `SETTINGS_OPTION`, `SOLUTION`, and add-mode `PROJECT` branches.
- Extends ADR 007 (buffer layout) and ADR 008 (`=` collapse from option lines); neither is
  superseded.
