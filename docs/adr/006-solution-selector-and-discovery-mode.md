# ADR 006: Solution selector — staged/unstaged model and discovery add-mode

**Status**: Accepted  
**Date**: 2026-06-20

## Context

ADR 004 introduced the `msvc://` interactive buffer and described the Solutions section layout. At that point, `:Msvc add` only accepted an explicit path or the current buffer — there was no way to browse `.sln` files in the workspace. Users working in repos with multiple solutions had to know and type full paths.

Two pain points remained:
1. On first use (empty `solutions` list), `:Msvc` opened the buffer with an empty Solutions section and no guidance on how to populate it.
2. `:Msvc add` with no argument silently fell through to a no-op when the active buffer was not a `.sln`.

## Decision

### `Discover.find_sln_files(cwd)`

A new function in `lua/msvc/discover.lua` scans a directory tree for `.sln` files without touching `solutions`. It is the only place filesystem discovery runs:

```
find_sln_files(cwd) → string[]
```

- Uses `rg --no-ignore --files --glob *.sln <cwd>` when `rg` is on `$PATH`.
- Falls back to `powershell -NoProfile -Command "Get-ChildItem -Recurse -Filter *.sln"` otherwise.
- Normalises all paths through `Util.normalize_path`, deduplicates case-insensitively, and returns a sorted list.
- Returns `{}` for a non-existent or non-directory `cwd`.

`rg` is preferred because it is significantly faster in large repos and respects `.rgignore` / `.ignore` files by default; `--no-ignore` is passed explicitly so that solutions inside `vendor` or similar excluded trees are still surfaced.

### Staged vs unstaged solutions

The `ui.lua` module tracks two solution sets during a session:

- **Staged** (`msvc.solutions`) — solutions the user has registered. These persist across buffer open/close cycles within the session.
- **Unstaged** (`_discovered`) — solutions found by `find_sln_files` but not yet registered. This list lives only in `ui.lua` module state and is reset when the buffer is unloaded.

This distinction avoids writing discovered paths into `solutions` until the user explicitly promotes them.

### Buffer modes: `"normal"` vs `"add"`

`ui.open(msvc, mode, discovered)` now accepts a `mode` parameter:

- **`"normal"`** — the existing layout (Settings, Pending, Solutions with projects). Solution lines support `<CR>` to activate and `-` to remove.
- **`"add"`** — an augmented layout that renders two groups under Solutions:

  ```
  Solutions

    Staged
      /path/to/Registered.sln
        ProjectA
        ProjectB

    Unstaged
      /path/to/Found.sln
  ```

  `Staged` shows `msvc.solutions`; `Unstaged` shows `_discovered` minus any already in `solutions`. When `_discovered` is empty (i.e. `find_sln_files` returned nothing), the Unstaged group is omitted. When `solutions` is empty, the Staged group is omitted.

### Keybindings on solution lines in add mode

| Line type | `<CR>` | `-` |
|---|---|---|
| `SOLUTION` (staged) | `set_solution` + re-render | Remove from `solutions`; clear active solution if it matched; move path to `_discovered` |
| `SOLUTION_UNSTAGED` | Stage into `solutions` + `set_solution` + re-render | Remove from `_discovered` (without staging) |
| `STAGED_HEADER` / `UNSTAGED_HEADER` | no-op | no-op |

In normal mode, `<CR>` on a `SOLUTION` line calls `set_solution` + re-renders; `-` removes from `solutions` and clears the active solution if it matched. Project lines (`PROJECT`) call `set_project` + re-render on `<CR>` in both modes.

### Discovery trigger points

`find_sln_files` is called in two situations, both in `commands.lua`:

1. **`:Msvc add` with no explicit path and current buffer is not a `.sln`.**
2. **`:Msvc` with no arguments when `#solutions == 0`** (which delegates to case 1).

In both situations the result is passed directly to `ui.open(msvc, "add", found_slns)`. No caching — each invocation runs a fresh scan. The cost is acceptable because discovery is only triggered interactively.

## Consequences

- First-time users see a guided picker rather than an empty buffer or an error.
- Discovery never writes to `solutions` implicitly; every registration is a deliberate `<CR>` on an unstaged line.
- The `_discovered` list is ephemeral — it is not persisted and is reset on `BufUnload`. A second `:Msvc add` call re-scans from scratch.
- `rg` is a soft dependency: its absence degrades gracefully to PowerShell. The PowerShell fallback is slower on very large trees but correct.
- `discover.lua` now has three public entry points: `parse_solution_projects`, `discover_targets`, and `find_sln_files`. The first two are called from `set_solution`; the third is called only from `commands.lua`.
- ADR 002's `:Msvc add` description is updated to document the discovery fallback. ADR 004's buffer layout description is superseded for the Solutions section by this ADR.
