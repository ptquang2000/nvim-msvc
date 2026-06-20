# ADR 007: msvc:// buffer v2 — target model, simplified layout, and highlight groups

**Status**: Accepted  
**Date**: 2026-06-20

## Context

ADR 004 introduced the `msvc://` buffer with a Pending section: the user pressed `b`/`c`/`r`/`f` on a specific solution or project line to stage an intent, then confirmed with `:w`. ADR 006 added staged/unstaged solution groups in add mode.

Three pain points remained:

1. **Cursor-dependent staging**: `b`/`c`/`r`/`f` required the cursor to be on a solution or project line, which broke flow when the user just wanted to switch from `build` to `clean` without repositioning.
2. **No colour**: all lines were monochrome; the buffer was hard to scan at a glance.
3. **`jobs` had no user-configurable default**: it initialised to `nil` per context, so every new context required the user to set it manually.

## Decision

### Buffer layout (normal mode)

```
Solution: /path/to/Active.sln       ← read-only label
Target: build                       ← read-only label; b/c/r/f switch value
Help: h?                            ← read-only label

  configuration  Debug              ← settings fields; = to expand options
  platform       x64
  arch           x64
  vs_version     latest
  jobs           6

────────────────────────────────    ← separator line (Comment hl)

  ProjectA                          ← - to select
* ProjectB                          ← selected project (* marker)
  ProjectC
```

The `# Settings`, `# Pending`, and `# Solutions` section headers are removed. Settings fields and projects are the only interactive body content.

### New entity types

| ENT constant | Meaning |
|---|---|
| `SOLUTION_HEADER` | `Solution: <path>` line — read-only |
| `TARGET_HEADER` | `Target: <value>` line — read-only |
| `HELP_HEADER` | `Help: h?` line — read-only |
| `SEPARATOR` | Visual separator between settings and projects |

`ENT.HEADER` (the old `msvc://` title line) is removed.

### Target model replaces Pending

A new module-level variable `_target` replaces `_pending`:

```lua
_target = "build"  -- "build" | "clean" | "rebuild" | "compile_file"
```

- `b` sets `_target = "build"`, re-renders.
- `c` sets `_target = "clean"`, re-renders.
- `r` sets `_target = "rebuild"`, re-renders.
- `f` sets `_target = "compile_file"`, re-renders. Requires `msvc.project` and `_source_file`; emits an error and does not change `_target` if either is missing.
- All four keys work regardless of cursor position.

`:w` fires `_target` against `msvc.solution` + `msvc.project`. The Pending section is removed; `_pending` state is removed.

### `-` selects / deselects project

`-` on a `PROJECT` line:
- If not the current `msvc.project`: call `set_project(ent.path)`, re-render.
- If already the current `msvc.project`: call `set_project("")` to clear, re-render.

When `msvc.project` is `nil`, `:w` builds the full solution. No explicit "select full solution" line is needed.

### `jobs` default via setup()

`Config.DEFAULT_SETTINGS.jobs` changes from `nil` to `6`. Users may override it in `setup()` by adding `default_settings = { jobs = N }` to their config table. `do_setup` reads `user_config.default_settings` and merges it over `Config.DEFAULT_SETTINGS`, storing the result as `Msvc._default_settings`. `_load_context` uses `Msvc._default_settings` instead of `Config.DEFAULT_SETTINGS` when initialising a new context key.

### Highlight groups

Defined once at plugin load via `vim.api.nvim_set_hl(0, name, { link = … })` with `default = true` so user overrides win. Applied per-line after each render via `nvim_buf_add_highlight`.

| Highlight group | Links to | Applied to |
|---|---|---|
| `MsvcHeaderLabel` | `Title` | `Solution:` / `Target:` / `Help:` keyword |
| `MsvcHeaderValue` | `Directory` | Path, target value, `h?` |
| `MsvcField` | `Identifier` | Settings field names |
| `MsvcValue` | `Constant` | Settings field values |
| `MsvcOption` | `Comment` | Non-selected expanded options |
| `MsvcOptionSelected` | `Statement` | Currently selected option (`> `) |
| `MsvcProject` | `Normal` | Project name |
| `MsvcProjectSelected` | `Special` | `*` marker on selected project |
| `MsvcSeparator` | `Comment` | Separator line |

Highlights are applied using column-range `nvim_buf_add_highlight` calls so the label and value of each header line can receive different groups on the same line.

### Add mode layout

Add mode retains the staged/unstaged solution groups (ADR 006) below the header and settings block, separated by the same separator line. The `-` toggle (stage ↔ unstaged) from ADR 006 is unchanged. `<CR>` on `SOLUTION_UNSTAGED` still stages and activates.

### Context store lifecycle tied to staged set

`_context_store` entries are only meaningful while the solution they belong to is staged. When a solution is unstaged (removed from `msvc.solutions` via `-`), all context keys whose solution component matches that path are immediately purged from `_context_store`.

The context key format is `<solution_path>\0<project_path>` (see ADR 001). Purging iterates the store and deletes every key that starts with `<unstaged_path>\0`. This is done via a new `Msvc:_discard_solution_context(path)` method in `init.lua`, called from the unstage handler in `ui.lua` after `msvc.solutions` is updated.

This ensures memory does not accumulate for solutions the user has explicitly discarded, and prevents stale settings from a removed solution from silently re-applying if the same path is staged again later.

## Consequences

- `b`/`c`/`r`/`f` are no longer cursor-sensitive — the build type can be switched from any line.
- The Pending section and `_pending` state are removed. `:w` always acts on the current `(msvc.solution, msvc.project, _target)` triple.
- A new context starts with `jobs = 6` (or the user-configured default) instead of `nil`, so builds no longer require manual job-count configuration.
- Colour adapts to any colorscheme via highlight linking; users may override any `Msvc*` group in their config.
- `<CR>` in normal mode has no remaining role on project lines (superseded by `-`). It is kept as a no-op to avoid accidental actions.
- Unstaging a solution discards its settings history. If it is staged again, it starts from defaults — intentional, since the user explicitly removed it.
- ADR 004's buffer layout and keybinding table are superseded by this ADR for normal mode. ADR 006's add-mode layout is unchanged.
