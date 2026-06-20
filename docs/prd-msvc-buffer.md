# PRD — Interactive msvc:// Build Buffer

*Generated from conversation context on 2026-06-20*

---

## Problem Statement

Configuring and triggering MSVC builds requires the user to remember and compose multiple
subcommands (`:Msvc solution`, `:Msvc project`, `:Msvc profile`, `:Msvc update`, `:Msvc build`).
There is no single place to see the full build context — active solution, pinned project,
and build settings — at once, nor to change it interactively. The profile system adds an
indirection layer (named profiles + overrides) that most users bypass with ad-hoc
`:Msvc update` calls anyway.

## Solution

Replace the command-driven UI with an interactive `msvc://` buffer (modelled on vim-fugitive).
`:Msvc` with no arguments opens the buffer. From it the user can inspect and change all
build settings, select the solution and project to build, stage a build/clean/rebuild or
single-file-compile action, and confirm with `:w`. The profile system is removed entirely;
each `(solution, project)` context pair stores a flat settings table directly.

## User Stories

1. As a developer, I want to open a single buffer that shows my current build configuration
   and all available solutions/projects, so I can review and change everything without
   leaving Neovim or typing subcommands from memory.

2. As a developer, I want to expand a settings field inline with `=` and pick a value with
   `-`, so I can switch from Debug to Release without remembering the exact configuration
   name.

3. As a developer, I want to navigate to a project line and press `b` to stage a build for
   that project, then press `:w` to fire it, so the flow is intentional and reviewable
   before MSBuild starts.

4. As a developer, I want each `(solution, project)` pair to remember its own settings
   independently, so switching between contexts within a session does not require
   re-configuring configuration/platform each time.

5. As a developer, I want to press `f` to stage a single-file compile for the source file
   I was editing when I opened the buffer, so I can get fast feedback on one translation
   unit without rebuilding the whole project.

6. As a developer, I want `l` to open the build log and `x` to cancel an in-flight build
   directly from the buffer, so I do not need to leave it for common reactive tasks.

7. As a developer, I want `:Msvc cancel` and `:Msvc log` to remain available as
   keyboard-mappable commands, so I can bind them globally without opening the buffer.

8. As a developer, I want to press `h?` to open a `msvc-help://` keybinding reference
   buffer, so I can look up keys without leaving the plugin.

## Implementation Decisions

### Modules to build or modify

**New — `lua/msvc/ui.lua`**

Owns everything about the `msvc://` buffer:
- `ui.open(msvc)` — opens (or focuses) the buffer, captures the calling buffer path for
  single-file compile, renders the initial layout.
- Internal render pipeline: writes Settings, Pending, and Solutions sections as buffer
  lines; stores a line→entity map so keyhandlers know what is under the cursor.
- Keybinding setup on buffer open (`b`, `c`, `r`, `f`, `l`, `x`, `=`, `-`, `h?`, `:w`).
- Pending-action state: a single table `{ action, solution, project }` cleared by `-` on
  the Pending section or reset after `:w`.
- `=` handler: expands the field under cursor by splicing option lines into the buffer and
  updating the line→entity map; `=` again (or moving away) collapses them.
- `-` handler: on an option line — sets the field value for the active context and
  re-renders; on the Pending line — clears the pending action.
- `:w` (`BufWriteCmd` autocmd on `msvc://`) — validates pending action, calls
  `msvc:set_solution()` / `msvc:set_project()`, dispatches the build, closes the buffer,
  opens the log buffer.

**New — `lua/msvc/ui_help.lua`** (or inline in `ui.lua`)

Renders the `msvc-help://` buffer — a static keybinding reference. Opened by `h?`.

**Modified — `lua/msvc/config.lua`**

- Remove: `profiles`, `default` (profile default), `default_profile`, `build_on_save`,
  `vs_prerelease`, `vs_products`, `msbuild_args` from schema.
- Remove: `get_profile()`, `list_profile_names()`, `PROFILE_FIELDS`, merge logic for
  the profile layer.
- Keep: `settings` layer (`vswhere_path`, `vs_requires`, `compile_commands`, `log_level`).
- Add: flat `SETTINGS_FIELDS` list (`configuration`, `platform`, `arch`, `vs_version`,
  `jobs`) for use by `ui.lua` when rendering the Settings section and validating values.
- Default settings values (used when a new context key is first seen):
  `{ configuration = nil, platform = nil, arch = "x64", vs_version = "latest", jobs = nil }`.

**Modified — `lua/msvc/init.lua`**

- Remove fields: `profile_name`, `overrides`.
- Remove methods: `set_profile()`, `active_profile()`, `set_override()`.
- Add field: `settings` — the flat settings table for the active context.
- Change `_context_store` payload from `{ profile_name, overrides }` to a flat settings
  table. `_save_context()` / `_load_context()` updated accordingly.
- `build()` reads from `self.settings` directly instead of `active_profile()`.
- `set_solution()` / `set_project()` unchanged in contract; only the context payload
  they save/restore changes.
- `setup()` no longer sets `profile_name`; removes `build_on_save` autocmd.
- `:Msvc` with no arguments calls `ui.open(self)` instead of printing help.

**Modified — `lua/msvc/commands.lua`**

- Remove subcommands: `build`, `rebuild`, `clean`, `solution`, `project`, `profile`,
  `update`, `status` and all associated completion functions.
- Keep: `cancel`, `log`.
- No-arg handler: delegate to `ui.open(msvc)`.
- Tab-completion for the two remaining subcommands only.

**Modified — `lua/msvc/discover.lua`**

- Add `discover_vcxproj_toolchain(vcxproj_path)` — parses `<WindowsTargetPlatformVersion>`
  and `<PlatformToolset>` from a `.vcxproj` XML. Returns `{ winsdk, vcvars_ver }`.
  Called by `ui.lua` when rendering settings for a context with a pinned project, and
  by `init.lua:build()` to resolve the hidden fields before spawning MSBuild.

**Modified — `lua/msvc/build.lua`**

- Remove `msbuild_args` from `Build.spawn` parameters.
- `target` parameter remains (used internally by `build()`, `clean()`, `rebuild()` dispatch);
  not user-configurable.
- `SolutionDir` pin logic for bare `.vcxproj` builds moves into `init.lua:build()` or
  stays in `build.lua` — no external API change.

### Interface changes

`Msvc:build(target_override)` signature unchanged. Internally reads `self.settings`
(flat table) instead of `self:active_profile()`.

`Build.spawn` drops `msbuild_args`. All other params unchanged.

### Context store schema change

Before: `_context_store[key] = { profile_name = "...", overrides = { ... } }`
After:  `_context_store[key] = { configuration = "Debug", platform = "x64", ... }`

In-memory only; no migration needed (state never persisted to disk).

### Single-file compile

`f` is only valid when a project is pinned. Dispatches:
```
MSBuild.exe <project.vcxproj> /t:ClCompile /p:SelectedFiles=<captured-file-path> ...
```
The source file is `vim.api.nvim_buf_get_name(0)` captured at `ui.open()` time, not at
`f`-press time. Error is emitted (not guessed) when no project is selected, because a
file can be included from multiple `.vcxproj` files.

### Settings field option sources (for `=` expansion)

| Field           | Options source |
|-----------------|----------------|
| `configuration` | `Discover.discover_targets(solution, project).configurations` |
| `platform`      | `Discover.discover_targets(solution, project).platforms` |
| `arch`          | Fixed: `{ "x86", "x64", "arm", "arm64" }` |
| `vs_version`    | `{ "latest", "2017", "2019", "2022" }` + vswhere installed versions |
| `jobs`          | Free-form number; no expansion list |

## Testing Decisions

**What makes a good test for this feature:**
- Tests for `ui.lua` should be pure unit tests against the render and state-machine logic,
  not integration tests that open real Neovim buffers. Extract the line→entity map builder
  and pending-action reducer as testable pure functions.
- Tests for `config.lua` changes should verify that the old profile-related API is gone
  and that flat settings defaults are correctly applied.
- Tests for `init.lua` context save/restore should verify the new payload schema.
- Tests for `discover.lua` should verify `discover_vcxproj_toolchain` parses both
  `<WindowsTargetPlatformVersion>` and `<PlatformToolset>` correctly from fixture XML.

**Modules to test:**

| Module | What to test |
|--------|-------------|
| `config.lua` | Flat settings defaults; removal of profile API; `SETTINGS_FIELDS` list |
| `init.lua` | `_save_context` / `_load_context` with flat payload; `build()` reads `self.settings` |
| `discover.lua` | `discover_vcxproj_toolchain` parses winsdk and toolset from fixture `.vcxproj` |
| `ui.lua` | Line→entity map construction; pending-action state transitions (`b`/`c`/`r`/`f`, `-`, `:w`); field expansion logic |

**Prior art to follow:**
- `config_spec.lua` — table-driven merge/validation tests; reset via `helpers.reset()` pattern.
- `discover_spec.lua` — fixture files under `tests/fixtures/` for parsing tests.
- `extensions_spec.lua` — event emission / listener patterns for testing bus interactions.

## Out of Scope

- Persisting context settings across Neovim sessions (remains in-memory only, per ADR 001).
- Fuzzy-finding solutions or projects from within the buffer (the Solutions list is the
  navigation surface; no separate picker).
- Multiple simultaneous pending actions (one pending slot only).
- Auto-detecting which `.vcxproj` owns a file for single-file compile (user must pin a
  project explicitly).
- Any change to how `BufEnter *.sln` populates `solution_candidates` (ADR 002 unchanged).
- Changes to `build.lua` beyond removing `msbuild_args`.
- Removing the `target` field from the internal build API.

## Further Notes

- ADR 002 (explicit-only solution population) and ADR 003 (context label in build command)
  are superseded by this change. Both are noted as superseded in ADR 004.
- The `cabbrev msvc Msvc` abbreviation is recommended in the README so users can type
  `:msvc` naturally; no code change needed.
- `vs_requires` stays in `setup()` config. Its vswhere filter role is unchanged.
- `compile_commands` config block stays in `setup()`. The post-build extractor flow is
  unchanged.
- Open question: should `jobs` support a free-form number entry in the buffer (user types
  the number) or a fixed pick-list? Current decision defers to a fixed pick-list matching
  the existing completion candidates (`1, 2, 4, 6, 8, 12, 16`), but this can be revisited.
