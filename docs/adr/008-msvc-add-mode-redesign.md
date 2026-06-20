# ADR 008: :Msvc add mode — dedicated layout, in-place mode switch, and = collapse fix

**Status**: Accepted  
**Date**: 2026-06-20

## Context

ADR 006 introduced add mode as an augmented layout of the same `msvc://` buffer. The add-mode layout inherited the full normal-mode header (Solution, Target, Help) and the Settings block even though neither is relevant when the user's only goal is to stage or unstage discovered solutions.

Three pain points remained:

1. **Target header and Settings block are dead weight in add mode** — they consume screen real estate and imply the user can edit settings, which has no effect until they enter normal mode.
2. **No visual distinction between Staged and Unstaged subheaders** — both rendered as plain text with no highlight, making them hard to scan.
3. **`=` could not collapse an expanded settings field when the cursor was on an option line** — pressing `=` only fired when cursor was on the `SETTINGS_FIELD` line itself; moving down into the option list left no way to collapse without moving back up.

## Decision

### Add mode layout

Add mode renders a minimal layout inside the same `msvc://` buffer (`_mode = "add"`):

```
Solution: /path/to/LastStaged.sln   ← _add_selected, empty if none
Help: h?

────────────────────────────────

  Staged                             ← MsvcStagedHeader
    * MySolution.sln                 ← * marks _add_selected
      OtherSolution.sln

  Unstaged                           ← MsvcUnstagedHeader
      Found.sln
```

- **No Target header.** `b`/`c`/`r`/`f` are no-ops in add mode.
- **No Settings block.** Settings are only meaningful in normal mode.
- The Separator appears between the header block and the solution lists (same as normal mode).
- Staged shows `msvc.solutions`; Unstaged shows `_discovered` minus already-staged paths.

### `_add_selected` — last staged solution

A new module-level variable tracks the last solution staged in the current add session:

```lua
_add_selected = nil  -- string path or nil
```

- Initialised to `msvc.solution` when `M.open()` is called with `mode = "add"`.
- Updated to a path whenever a solution is staged (via `<CR>` on `SOLUTION_UNSTAGED`, or `-` on `SOLUTION_UNSTAGED`).
- Cleared to `nil` when the `_add_selected` path is unstaged via `-` on `SOLUTION`.
- Shown in the `Solution:` header line; the matching staged entry is marked with `*`.

### Keybindings in add mode

| Key    | Line type          | Action |
|--------|--------------------|--------|
| `<CR>` | `SOLUTION_UNSTAGED`| Stage → `_add_selected = path` → `msvc:set_solution(path)` → `_mode = "normal"` → re-render |
| `<CR>` | `SOLUTION`         | `msvc:set_solution(path)` → `_mode = "normal"` → re-render |
| `-`    | `SOLUTION_UNSTAGED`| Stage → `_add_selected = path` → re-render (no mode switch) |
| `-`    | `SOLUTION`         | Unstage; if path == `_add_selected` → clear `_add_selected`; discard context → re-render |
| `:w`   | —                  | If `_add_selected` nil → `Log:warn` and return; else `msvc:set_solution(_add_selected)` → `_mode = "normal"` → re-render |
| `h?`   | —                  | Open help buffer (same as normal mode) |
| `q`    | —                  | Close buffer (same as normal mode) |
| `l`    | —                  | Open log buffer (same as normal mode) |
| `x`    | —                  | Cancel in-flight build (same as normal mode) |
| `b`/`c`/`r`/`f` | — | No-op in add mode |

`<CR>` and `:w` both switch mode in-place — the `msvc://` buffer content transitions to the normal-mode layout without closing or re-opening the buffer.

### New highlight groups

Two new groups added to `setup_highlights()`:

| Group               | Links to  | Applied to            |
|---------------------|-----------|-----------------------|
| `MsvcStagedHeader`  | `Title`   | `Staged` subheader    |
| `MsvcUnstagedHeader`| `Comment` | `Unstaged` subheader  |

### `=` collapse fix for SETTINGS_OPTION lines

The `=` keymap handler is extended to also fire when the cursor is on a `SETTINGS_OPTION` line:

```lua
map("=", function()
    local ent = entity_at_cursor()
    if not ent then return end
    if ent.type == ENT.SETTINGS_FIELD then
        _expanded_field = (_expanded_field == ent.field) and nil or ent.field
        render(msvc, buf)
    elseif ent.type == ENT.SETTINGS_OPTION then
        _expanded_field = nil
        render(msvc, buf)
    end
end)
```

This allows the user to collapse an expanded field from any line within the option list, not just the field header line.

## Consequences

- Add mode is now visually distinct from normal mode: no Target header, no Settings block.
- `_add_selected` makes `:w` in add mode deterministic — the header always shows what `:w` will activate.
- Pressing `<CR>` on any solution in add mode transitions in-place to normal mode, replacing the full open/close/reopen cycle.
- `b`/`c`/`r`/`f` become no-ops in add mode — the target value is preserved and takes effect when normal mode is entered.
- `=` can now collapse an expanded settings field regardless of cursor position within the expanded block.
- ADR 006's add-mode keybinding table and ADR 007's add-mode layout description are superseded by this ADR.
