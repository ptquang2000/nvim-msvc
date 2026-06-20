# PRD — Solution Selector & Discovery Mode

*Generated from conversation context on 2026-06-20*

---

## Problem Statement

When a user invokes `:Msvc`, the buffer opens and immediately renders all registered solutions in a flat list. There is no guided flow — users without a solution registered see an unhelpful placeholder, and users with multiple solutions must remember to navigate the list manually. Separately, `:Msvc add` with no argument or a non-.sln buffer simply errors out, forcing users to manually locate and type a `.sln` path even when the plugin could find it for them.

## Solution

Two complementary changes:

1. **Solution selector on `:Msvc`**: gating logic before opening the buffer. Zero registered solutions falls through to discovery; exactly one auto-selects; multiple opens the buffer with `<CR>` as the activation key. The `msvc://` buffer gains `<CR>` keybindings on solution and project lines.

2. **Discovery mode on `:Msvc add`**: when no `.sln` path is available (no argument, not on a `.sln` buffer), search `cwd` recursively for `.sln` files using `rg` (no gitignore) or PowerShell, then open `msvc://` in "add mode" — a two-group Solutions view distinguishing staged (registered) and unstaged (just discovered) solutions, with `-` to toggle and `<CR>` to stage-and-activate.

Additionally, rename the internal field `solution_candidates` → `solutions` to align with the new staged/unstaged terminology.

## User Stories

1. As a user with no registered solutions, I want `:Msvc` to automatically run discovery so I can pick a solution without typing its path.
2. As a user with exactly one registered solution, I want `:Msvc` to auto-select it and open the buffer immediately so I don't need an extra confirmation step.
3. As a user with multiple registered solutions, I want to press `<CR>` on a solution line in `msvc://` to activate it, so I can switch context without leaving the buffer.
4. As a user, I want to press `<CR>` on a project line in `msvc://` to pin it as the active project.
5. As a user running `:Msvc add` from a non-.sln buffer, I want the plugin to search `cwd` recursively for `.sln` files (ignoring `.gitignore`) so I can discover and stage solutions in a large repo.
6. As a user in add mode, I want to see staged and unstaged solutions in separate groups so I can tell at a glance which solutions are registered and which were just discovered.
7. As a user in add mode, I want `-` on a staged solution to unstage it and `-` on an unstaged solution to stage it, so I can manage the registered set without using subcommands.
8. As a user, I want `rg` used for discovery when available (fast, no gitignore) and PowerShell as a fallback, so discovery works correctly in all Windows environments.

## Implementation Decisions

### Rename: `solution_candidates` → `solutions`

The field on the `Msvc` singleton, all internal references, and all tests are updated. "Candidates" implied a pre-selection pool; "solutions" reflects the settled meaning — the set of registered (staged) solutions.

### `:Msvc` (no args) — gating dispatch in `commands.lua`

```
#solutions == 0  → SUBCOMMANDS.add.run(msvc, {})      (fall through to discovery)
#solutions == 1  → set_solution(solutions[1]); ui.open(msvc, "normal")
#solutions > 1   → ui.open(msvc, "normal")
```

No new subcommand. The zero-solutions case reuses the `:Msvc add` path entirely.

### `:Msvc add` — path-or-discovery branch in `commands.lua`

```
argument given AND is .sln   → existing behavior (add + activate, no buffer opened)
current buffer is .sln       → existing behavior
otherwise                    → Discover.find_sln_files(cwd); ui.open(msvc, "add", found)
```

Existing behavior (path given) is unchanged and does not open the buffer.

### `Discover.find_sln_files(cwd)` — new function in `discover.lua`

Separate from the existing `find_slns()` (which uses `vim.fn.globpath` and respects gitignore). New function:

- `vim.fn.executable("rg") == 1` → `rg --no-ignore --files --glob "*.sln" <cwd>`
- otherwise → PowerShell `Get-ChildItem -Path <cwd> -Recurse -Filter "*.sln" | Select-Object -ExpandProperty FullName`

Runs synchronously via `vim.fn.system()`. Results are normalized and sorted.

### `ui.lua` — mode and discovered state

Two new module-level vars:
- `_mode = "normal" | "add"` — controls whether the Unstaged sub-group is rendered.
- `_discovered = {}` — paths found by discovery, filtered to exclude already-staged solutions. Populated at `open()` time in add mode. Cached (not re-searched on buffer re-render).

`open(msvc, mode, discovered)` signature: `_mode` and `_discovered` are always set at call time, even when reusing an existing buffer, so `:Msvc add` on an already-open buffer correctly switches it to add mode.

### `ui.lua` — new ENT types

- `ENT.STAGED_HEADER` — "  Staged" label line in add mode
- `ENT.UNSTAGED_HEADER` — "  Unstaged" label line in add mode  
- `ENT.SOLUTION_UNSTAGED` — a discovered-but-not-staged solution row (carries `path`)

### `ui.lua` — Solutions section layout

**Normal mode** (unchanged):
```
# Solutions
  * MySolution.sln
    ProjectA
    ProjectB
  Other.sln
    ProjectC
```

**Add mode**:
```
# Solutions
  Staged
  * MySolution.sln
    ProjectA

  Unstaged
    FoundDeep.sln
    Another.sln
```

### `ui.lua` — keybinding changes

| Key | Entity | Action |
|-----|--------|--------|
| `<CR>` | `SOLUTION` | `set_solution()`, re-render (stays open) |
| `<CR>` | `SOLUTION_UNSTAGED` | add to `solutions`, `set_solution()`, re-render |
| `<CR>` | `PROJECT` | `set_project()`, re-render |
| `-` | `SOLUTION` (staged) | remove from `solutions`; if active solution, clear `msvc.solution/project`; in add mode move back to `_discovered`; re-render |
| `-` | `SOLUTION_UNSTAGED` | add to `solutions`, remove from `_discovered`, re-render |
| `-` | `SETTINGS_OPTION` / `PENDING` | unchanged |

`<CR>` on any other entity type (SECTION, BLANK, HEADER, SETTINGS_FIELD, PENDING) is a no-op.

### `_reset()` update

Add `_mode = "normal"` and `_discovered = {}` to the reset function exposed for unit tests.

## Testing Decisions

### What makes a good test

- **`find_sln_files`**: stub `vim.fn.executable` and `vim.fn.system`; assert correct command constructed for rg vs PowerShell path; assert normalization and dedup of output.
- **`commands.lua` dispatch**: stub `ui.open` and `Discover.find_sln_files`; cover the three `#solutions` branches; cover the path-vs-discovery branch in `add`.
- **`ui.lua` — add mode layout**: use `_build_entries` with a fake msvc + `_set_mode`/`_set_discovered` helpers; assert Staged and Unstaged headers appear in the right positions; assert `SOLUTION_UNSTAGED` entities carry correct paths.
- **`ui.lua` — `-` and `<CR>` on solution lines**: drive keymaps via the existing `setup_keymaps`-then-feed-key pattern from `ui_spec.lua`; assert `msvc.solutions` mutates correctly and re-render happens.

### Modules to test

- `discover.lua` — `find_sln_files` (new, unit-testable via stubs)
- `commands.lua` — `:Msvc` dispatch and `:Msvc add` discovery branch
- `ui.lua` — add mode `build_entries`, `-` and `<CR>` keybindings on solution/project lines

### Prior art to follow

- `lua/msvc/test/ui_spec.lua` for `_build_entries` and keymap-feed patterns
- `tests/commands_spec.lua` for `:Msvc add` path-based tests
- `lua/msvc/test/discover_spec.lua` for `vim.fn.system` stub patterns

## Out of Scope

- Persistent storage of staged solutions across Neovim sessions (solutions list lives in memory).
- Fuzzy-finder integration (no Telescope/fzf picker — `vim.ui.select` not used; the buffer IS the picker).
- Discovery from directories other than `cwd` (no buffer-directory scan, no arglist).
- Depth limiting or progress feedback for large discovery searches.
- `:Msvc add` opening the buffer when a valid path is provided (existing silent behavior retained).
- Any changes to `b`/`c`/`r`/`f` staging keybindings.

## Further Notes

- `Discover.find_slns()` (existing, uses `globpath`, respects gitignore) is left in place — it may be used by other callers or tests. `find_sln_files` is additive.
- PowerShell discovery may be slower than `rg` on large repos; no async handling is planned. If this becomes a pain point, async via `vim.system()` (nvim 0.10+) is a natural next step.
- The `set_solution()` method currently looks up candidates by path/basename; after the rename it searches `self.solutions`. The lookup logic is unchanged — only the field name changes.
- ADR 004 describes the buffer model; this change should be reflected in an update to ADR 004 or a new ADR 006 covering the staged/unstaged solution concept and discovery mode.
