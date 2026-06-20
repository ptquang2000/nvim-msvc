# ADR 004: Interactive msvc:// buffer replaces profile system and command surface

**Status**: Accepted  
**Date**: 2026-06-20

## Context

The plugin's build configuration was managed through named profiles defined in `setup()`
(`config.profiles`) plus per-session overrides applied via `:Msvc update`. This required
users to know profile names, remember which profile was active per context, and use
multiple subcommands to inspect or change build settings. The command surface had grown
to include `build`, `rebuild`, `clean`, `cancel`, `log`, `solution`, `project`, `profile`,
`update`, and `status`.

Two pain points drove this change:
1. The profile abstraction added indirection without benefit — most users kept one profile
   and used `:Msvc update configuration Release` ad-hoc anyway.
2. There was no single place to see and change the full build context (solution, project,
   settings) at once.

## Decision

### Remove the profile system entirely

`config.profiles`, `profile_name`, `set_profile()`, `active_profile()`, and the `overrides`
table are all removed. Each context key `(solution, project)` in `_context_store` now holds
a **flat settings table** directly:

```lua
{ configuration = "Debug", platform = "x64", arch = "x64", vs_version = "latest", jobs = 4 }
```

No profile indirection. No default/named merging.

### Introduce the msvc:// interactive buffer

`:Msvc` with no arguments opens `msvc://` — a fugitive-style special buffer that is the
primary UI for all build configuration and dispatch.

**Buffer layout:**
```
msvc://

Settings
  configuration  Debug
  platform       x64
  arch           x64
  vs_version     latest
  jobs           4

Pending
  [build] MySolution.sln > ProjectA

Solutions
  MySolution.sln
    ProjectA
    ProjectB
  OtherSolution.sln
    ProjectC
```

**Keybindings (msvc:// buffer only):**

| Key  | Action |
|------|--------|
| `b`  | Stage build for solution/project under cursor |
| `c`  | Stage clean |
| `r`  | Stage rebuild |
| `f`  | Stage single-file compile (file captured at buffer open time) |
| `l`  | Open log buffer immediately |
| `x`  | Cancel in-flight build immediately |
| `=`  | Expand / collapse field options inline |
| `-`  | Select highlighted option; clear Pending when cursor is on that section |
| `:w` | Confirm staged action → close buffer → open log |
| `h?` | Open `msvc-help://` keybinding reference buffer |

**Settings fields shown in the buffer:** `configuration`, `platform`, `arch`,
`vs_version`, `jobs`. Fields `winsdk` and `vcvars_ver` are auto-detected from
`<WindowsTargetPlatformVersion>` and `<PlatformToolset>` in the active `.vcxproj` and
are not shown. Plugin-level config (`vswhere_path`, `vs_requires`, `compile_commands`)
stays in `setup()` and is never shown in the buffer.

**Field option expansion:** pressing `=` on a Settings field expands a list of known
values inline below the field line. Pressing `-` on an expanded option selects it and
collapses the list. `=` again collapses without selecting. Options for `configuration`
and `platform` are parsed from the active `.sln`; `arch` uses a fixed list; `vs_version`
queries vswhere.

**Pending action model:** `b`/`c`/`r`/`f` write a staged intent line into the Pending
section. The user may continue adjusting Settings before pressing `:w`. `-` on the
Pending section line clears it. `:w` on an empty Pending section is a no-op.

**Single-file compile (`f`):** requires a `.vcxproj` to be selected (not just a solution).
If no project is selected when `f` is pressed, the plugin emits a clear error — it does
not guess the owning project, because a source file can be included from multiple projects.
The file is the buffer active at the moment `:Msvc` was invoked.

**After `:w`:** the buffer closes, the pending `(solution, project)` context is activated
via `set_solution()` / `set_project()`, the build is dispatched, and the log buffer opens.

### Reduce the command surface

Three `:Msvc` subcommands survive:
- `:Msvc add [path]` — register a `.sln` and select it (see ADR 002)
- `:Msvc cancel` — cancel an in-flight build (also available as `x` inside the buffer)
- `:Msvc log` — open the log buffer (also available as `l` inside the buffer)

All other subcommands (`build`, `rebuild`, `clean`, `solution`, `project`, `profile`,
`update`, `status`) are removed. Their functionality lives in the `msvc://` buffer.

### New module: ui.lua

A new `lua/msvc/ui.lua` module owns the buffer: rendering, keybinding setup, state
for the pending action, and the open-time source-buffer capture. It is the only module
that creates or writes to `msvc://` buffers.

## Consequences

- Users interact with a single buffer rather than memorising subcommand syntax.
- Named profiles are a breaking change for anyone using `config.profiles` in their
  `setup()` call — they must migrate to the flat per-context model.
- `msbuild_args`, `vs_prerelease`, `vs_products`, and `build_on_save` are removed from
  the config schema entirely. `target` is retained internally (used by build/clean/rebuild
  dispatch) but is not user-editable.
- The `_context_store` schema changes: stored values are flat settings tables, not
  `{ profile_name, overrides }` pairs. Existing in-memory state from before this change
  is incompatible; since context state never persisted to disk, there is no migration
  concern.
- ADR 001's context save/restore mechanism is preserved unchanged — only the payload
  stored per key changes.
- ADR 002 (explicit-only solution population) and ADR 003 (context label in build
  command) are superseded: solution and project selection move fully into the buffer,
  and the `build [context-label]` command is removed.
