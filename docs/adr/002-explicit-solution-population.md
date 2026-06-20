# ADR 002: Explicit-only solution population

**Status**: Accepted  
**Date**: 2026-06-08  
**Amended**: 2026-06-20

## Context

The plugin previously populated `solution_candidates` automatically at startup via `Msvc:discover_solution()`: a `git ls-files` walk across the whole repository, followed by an upward directory walk as a non-git fallback, plus a shallow filesystem scan of the active profile's `compile_commands.builddir`. A `:Msvc discover` subcommand allowed manual re-runs.

This produced two complaints:
- In large repos the startup scan was slow and surfaced solutions the user had no intent to build.
- The auto-selected solution was surprising when multiple `.sln` files exist (the heuristic preferred root-level files, which is not always right).

## Decision

Remove all implicit solution scanning. `solution_candidates` is populated in exactly two ways:

1. **Startup single-sln check** — `setup()` performs a shallow `glob(cwd .. "/*.sln")`. If exactly one `.sln` is present in `cwd`, it is added to `solution_candidates` and selected via `set_solution()`. If zero or more than one are found, nothing is auto-selected.
2. **`:Msvc add [path]`** — an explicit user command that registers a `.sln` and selects it. When no path is given it operates on the current buffer. Tab-completion after `add` returns filesystem paths.

The `Msvc:discover_solution()` method, the netrw directory `BufEnter` autocmd, the `:Msvc discover` subcommand, and the `BufEnter *.sln` autocmd are all removed.

## Consequences

- No startup scanning cost. The plugin is instant in large monorepos.
- `solution_candidates` only contains solutions the user has explicitly registered. `:Msvc solution <tab>` is short and intentional.
- A user opening nvim in a directory with multiple `.sln` files sees no auto-selection; they open one and run `:Msvc add` to register it, or pass a full path directly.
- Revisiting a previously-opened `.sln` buffer no longer silently switches the active solution.
- The `discover.lua` module is retained for `parse_solution_projects()` and `discover_targets()`, which are still needed by `set_solution()` and field completions.
- ADR 001's note that `discover_solution()` bypassed context save/restore is now moot; all solution selection goes through `set_solution()`.
