# ADR 002: Explicit-only solution population

**Status**: Accepted  
**Date**: 2026-06-08  
**Amended**: 2026-06-20 (discovery fallback for `:Msvc add`; `solutions` rename; no-args gating)

## Context

The plugin previously populated `solution_candidates` automatically at startup via `Msvc:discover_solution()`: a `git ls-files` walk across the whole repository, followed by an upward directory walk as a non-git fallback, plus a shallow filesystem scan of the active profile's `compile_commands.builddir`. A `:Msvc discover` subcommand allowed manual re-runs.

This produced two complaints:
- In large repos the startup scan was slow and surfaced solutions the user had no intent to build.
- The auto-selected solution was surprising when multiple `.sln` files exist (the heuristic preferred root-level files, which is not always right).

## Decision

Remove all implicit solution scanning. The `solutions` list (formerly `solution_candidates`) is populated in exactly two ways:

1. **Startup single-sln check** — `setup()` performs a shallow `glob(cwd .. "/*.sln")`. If exactly one `.sln` is present in `cwd`, it is added to `solutions` and selected via `set_solution()`. If zero or more than one are found, nothing is auto-selected.
2. **`:Msvc add [path]`** — an explicit user command that registers a `.sln` and selects it:
   - **Explicit path given** — validates the `.sln` extension and file existence, then calls `add_and_activate`.
   - **No path, current buffer is a `.sln`** — uses the buffer path as the target.
   - **No path, current buffer is not a `.sln`** — enters *Discovery Mode*: calls `Discover.find_sln_files(cwd)` and opens the `msvc://` buffer in `"add"` mode showing staged and unstaged solutions (see ADR 006). Tab-completion after `add` returns filesystem paths.

### `:Msvc` no-args gating dispatch

When `:Msvc` is invoked with no arguments, `commands.lua` gates on the size of `solutions`:

| `#solutions` | Behavior |
|---|---|
| 0 | Delegates to `SUBCOMMANDS.add.run(msvc, {})`, entering Discovery Mode as above |
| 1 | Calls `set_solution(solutions[1])` then opens the buffer in `"normal"` mode |
| ≥ 2 | Opens the buffer in `"normal"` mode directly |

This means a first-time user who has never registered a solution can simply run `:Msvc` and the plugin guides them through discovery rather than doing nothing or erroring.

The `Msvc:discover_solution()` method, the netrw directory `BufEnter` autocmd, the `:Msvc discover` subcommand, and the `BufEnter *.sln` autocmd are all removed.

## Consequences

- No startup scanning cost. The plugin is instant in large monorepos.
- `solutions` only contains solutions the user has explicitly registered. `:Msvc solution <tab>` is short and intentional.
- A user opening nvim in a directory with multiple `.sln` files sees no auto-selection; running `:Msvc` or `:Msvc add` enters Discovery Mode and lets them pick interactively.
- Revisiting a previously-opened `.sln` buffer no longer silently switches the active solution.
- The `discover.lua` module is retained and extended: `parse_solution_projects()` and `discover_targets()` are still needed by `set_solution()` and field completions; `find_sln_files(cwd)` is now also exported (see ADR 006).
- ADR 001's note that `discover_solution()` bypassed context save/restore is now moot; all solution selection goes through `set_solution()`.
