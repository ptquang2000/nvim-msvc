# PRD — msvc:// buffer v2: target model, simplified layout, highlights, and context lifecycle

*Generated from conversation context on 2026-06-20*

---

## Problem Statement

The `msvc://` buffer (ADR 004, ADR 006) is functional but has three friction points:

1. **Cursor-dependent build staging**: pressing `b`/`c`/`r`/`f` only works when the cursor is on a solution or project line. Switching from `build` to `clean` requires moving the cursor first, which breaks flow.
2. **No colour**: all lines render identically; users cannot scan the buffer at a glance to distinguish headers, settings, project names, or the active selection.
3. **`jobs` has no sensible default**: it initialises to `nil` per context, forcing manual configuration before every build in a new session.

Additionally, the Pending section adds a layer of indirection (stage → inspect → confirm) that is unnecessary when the build target is already visible as a header value.

## Solution

Four complementary changes:

1. **Target model**: replace the `_pending` / Pending-section staging workflow with a persistent `_target` variable (`"build"` by default). `b`/`c`/`r`/`f` switch `_target` from anywhere in the buffer. `:w` always fires `(msvc.solution, msvc.project, _target)` — no staging step, no cursor positioning.

2. **Simplified buffer layout**: the buffer header becomes three read-only label lines (`Solution:`, `Target:`, `Help:`). Settings fields appear below the header without a section heading. A visual separator divides settings from the project list. The Pending section is removed.

3. **Highlight groups**: nine `Msvc*` highlight groups linked to semantic Neovim groups (`Title`, `Directory`, `Identifier`, `Constant`, `Comment`, `Statement`, `Special`, `Normal`) so the buffer adapts to any colorscheme. Applied via column-range `nvim_buf_add_highlight` calls after each render.

4. **`jobs` default and context lifecycle**: `jobs` defaults to `6` (overridable via `setup()`). When a solution is unstaged, all `_context_store` entries for that solution are discarded immediately — context is only kept for staged solutions.

## User Stories

1. As a user, I want to press `b`/`c`/`r`/`f` from any line in the buffer to switch the build type, so I don't have to reposition the cursor before changing from `build` to `clean`.
2. As a user, I want the active build type displayed as `Target: build` in the buffer header, so I always know what `:w` will dispatch without scanning the Pending section.
3. As a user, I want to press `-` on a project line to select or deselect it as the build scope, so I can target a single project or the full solution with one keystroke.
4. As a user with no project selected, I want `:w` to build the full solution implicitly, so I don't need an explicit "select full solution" action.
5. As a user, I want the `msvc://` buffer to use colour so I can immediately distinguish headers, settings, and project lines.
6. As a user, I want `jobs` to default to `6` without manual configuration, so builds are parallel out of the box.
7. As a user, I want to override the default `jobs` value in `setup()`, so teams can set a project-wide default.
8. As a user, I want the context (settings) for an unstaged solution to be discarded when I remove it, so stale settings don't silently re-apply if I re-stage the same solution later.
9. As a user in add mode, I want `-` on a staged solution to unstage it (and discard its context) and `-` on an unstaged solution to stage it, so I can manage the registered set with a single key.

## Implementation Decisions

### `config.lua` — `jobs` default and `default_settings` override

`Config.DEFAULT_SETTINGS.jobs` changes from `nil` to `6`. A new `default_settings` key is recognised in the user's `setup()` config table; `merge_config` merges it over `DEFAULT_SETTINGS` and the result is stored as `Msvc._default_settings`. `_load_context` uses `Msvc._default_settings` instead of the module-level `Config.DEFAULT_SETTINGS` when initialising a new context key.

### `init.lua` — `_discard_solution_context(path)`

New method on the `Msvc` singleton. Iterates `_context_store` and deletes every key whose solution component (the substring before the `\0` separator, per ADR 001's `make_context_key` format) matches the given path (case-insensitive). Called from `ui.lua`'s unstage handler after `msvc.solutions` is updated.

### `ui.lua` — new entity types

| ENT constant | Purpose |
|---|---|
| `SOLUTION_HEADER` | `Solution: <path>` — read-only |
| `TARGET_HEADER` | `Target: <value>` — read-only; updated on b/c/r/f |
| `HELP_HEADER` | `Help: h?` — read-only |
| `SEPARATOR` | Visual line between settings and projects |

`ENT.HEADER` (the old `msvc://` title line) is removed.

### `ui.lua` — `_target` replaces `_pending`

```lua
_target = "build"  -- "build" | "clean" | "rebuild" | "compile_file"
```

- `b`/`c`/`r`/`f` set `_target` and re-render. `f` validates that `msvc.project` and `_source_file` are set before switching; emits an error and leaves `_target` unchanged if either is missing.
- `_pending` state, the Pending section, and `fire_pending()` are removed.
- `BufWriteCmd` reads `_target` directly; `_reset()` sets `_target = "build"`.

### `ui.lua` — `-` on project lines

`-` on a `PROJECT` entity: if `ent.path ~= msvc.project`, call `set_project(ent.path)`; if already selected, call `set_project("")` to deselect (full-solution scope). Re-render after either branch.

### `ui.lua` — highlights

Highlight groups are defined once via `vim.api.nvim_set_hl(0, name, { link = …, default = true })` so user overrides always win. After each `render()` call, `nvim_buf_add_highlight` applies column-range highlights per line based on entity type. The label half and value half of header lines receive different groups on the same line (`MsvcHeaderLabel` vs `MsvcHeaderValue`).

| Group | Links to | Applied to |
|---|---|---|
| `MsvcHeaderLabel` | `Title` | `Solution:` / `Target:` / `Help:` keyword |
| `MsvcHeaderValue` | `Directory` | Path, target name, `h?` |
| `MsvcField` | `Identifier` | Settings field names |
| `MsvcValue` | `Constant` | Settings field values |
| `MsvcOption` | `Comment` | Non-selected expanded options |
| `MsvcOptionSelected` | `Statement` | Selected option (`> ` prefix) |
| `MsvcProject` | `Normal` | Project name text |
| `MsvcProjectSelected` | `Special` | `*` marker on selected project |
| `MsvcSeparator` | `Comment` | Separator line |

### `ui.lua` — add mode

Add mode retains the staged/unstaged solution groups (ADR 006) below the header + settings block, divided by the same separator. The `-` toggle (stage ↔ unstage) now also calls `msvc:_discard_solution_context(path)` on unstage. `<CR>` on `SOLUTION_UNSTAGED` still stages and activates. `_target` persists across mode switches.

### Buffer layout (normal mode)

```
Solution: /path/to/Active.sln     ← MsvcHeaderLabel + MsvcHeaderValue
Target: build                     ← MsvcHeaderLabel + MsvcHeaderValue
Help: h?                          ← MsvcHeaderLabel + MsvcHeaderValue

  configuration  Debug            ← MsvcField + MsvcValue
  platform       x64
  arch           x64
  vs_version     latest
  jobs           6

────────────────────────────────  ← MsvcSeparator

  ProjectA                        ← MsvcProject
* ProjectB                        ← MsvcProjectSelected (* marker) + MsvcProject
  ProjectC
```

### Keybinding table (updated)

| Key | Action |
|---|---|
| `b` | Set `_target = "build"`, re-render |
| `c` | Set `_target = "clean"`, re-render |
| `r` | Set `_target = "rebuild"`, re-render |
| `f` | Set `_target = "compile_file"` if project + source file present, else error |
| `=` | Expand / collapse settings field options |
| `-` | Project: select/deselect; Settings option: apply value; Solution (add mode): stage/unstage |
| `<CR>` | Solution_Unstaged (add mode): stage + activate; all other types: no-op |
| `:w` | Fire `_target` against `(solution, project)`, close buffer, open log |
| `l` | Open log buffer |
| `x` | Cancel in-flight build |
| `h?` | Open `msvc-help://` |
| `q` | Close buffer |

## Testing Decisions

### What makes a good test

- **`config.lua` — `default_settings` merge**: pass `{ default_settings = { jobs = 12 } }` to `merge_config`; assert `_default_settings.jobs == 12`. Pass no `default_settings`; assert `_default_settings.jobs == 6`.
- **`init.lua` — `_discard_solution_context`**: populate `_context_store` with several keys (some matching the target solution, some not); call the method; assert matching keys are gone and non-matching keys survive.
- **`ui.lua` — `build_entries` structural**: use `_build_entries` with a `fake_msvc`; assert `SOLUTION_HEADER`, `TARGET_HEADER`, `HELP_HEADER`, and `SEPARATOR` entities appear in the correct order; assert no `PENDING` or `ENT.HEADER` entity is present.
- **`ui.lua` — `_target` keybindings**: use the `setup_keymaps`-then-`nvim_feedkeys` pattern from `ui_spec.lua`; assert `UI._get_target()` changes correctly after feeding `b`/`c`/`r`; assert `f` without a project leaves `_target` unchanged.
- **`ui.lua` — `-` on project select/deselect**: feed `-` on a project line; assert `msvc.project` updates. Feed `-` again on the same line; assert `msvc.project` clears.
- **`ui.lua` — unstage discards context**: stub `msvc:_discard_solution_context`; feed `-` on a staged solution in add mode; assert the stub was called with the correct path.
- **`ui.lua` — highlight calls**: spy on `nvim_buf_add_highlight`; call `render`; assert header lines produce two separate hl calls (label column range + value column range).

### Modules to test

- `config.lua` — `default_settings` merge
- `init.lua` — `_discard_solution_context`, `_load_context` uses `_default_settings`
- `ui.lua` — layout, `_target` keybindings, `-` project toggle, unstage → discard, highlight application

### Prior art to follow

- `lua/msvc/test/ui_spec.lua` — `fake_msvc`, `_build_entries` structural assertions, `setup_keymaps`-then-feedkeys pattern
- `lua/msvc/test/init_spec.lua` — `_context_store` population and assertion patterns
- `lua/msvc/test/config_spec.lua` — `merge_config` unit test structure

## Out of Scope

- Persistent `_target` across Neovim sessions (in-memory only).
- Per-project default settings (the `default_settings` override applies globally).
- Fuzzy-finder integration for project selection.
- Async highlight computation (all highlights applied synchronously after render).
- Any changes to the `msvc-help://` buffer content (keybinding reference not updated here).
- Changes to add-mode layout beyond the header, separator, and context-discard on unstage.

## Further Notes

- `<CR>` in normal mode is kept as a no-op on all entity types to prevent accidental actions; its prior role (activate solution / pin project) is superseded by `-`.
- The separator line character (`─`) uses U+2500 (BOX DRAWINGS LIGHT HORIZONTAL). Width should match the longest settings line or a fixed constant (e.g. 40 chars) — not the window width, since the buffer may be viewed in a split.
- `_discard_solution_context` uses a case-insensitive match on the solution path component to be consistent with how Windows paths are compared elsewhere in the plugin.
- If `msvc.solution` is `nil` when `:w` is pressed, the existing error path in `build()` handles it — no new guard needed in `ui.lua`.
