# Architecture

`nvim-msvc` is intentionally small. The whole plugin is a single
singleton (`require('msvc')`) plus a handful of stateless helper modules.

## Module layout

```
lua/msvc/
  init.lua              The Msvc singleton + setup() entry point.
  config.lua            Schema, merge, validate. settings layer only (no profiles).
  commands.lua          :Msvc subcommand dispatcher — only `cancel` and `log` remain.
  ui.lua                The msvc:// interactive buffer (layout, keybindings, render).
  build.lua             Spawn MSBuild via vim.system; cancel via taskkill /T /F /PID.
  devenv.lua            Run vcvarsall.bat in cmd.exe; cache the resulting env.
  vswhere.lua           JSON wrapper around vswhere.exe (sync + async).
  discover.lua          Parse .sln projects and configuration/platform targets; shallow single-sln startup scan.
  compile_commands.lua  Drive msbuild-extractor-sample; generate compile_commands.json + .clangd (with WDK km\ paths and arch/OS defines for kernel-mode projects).
  log.lua               vim.notify wrapper + live-tail buffer for build output (opens as horizontal split).
  ui_help.lua           The msvc-help:// keybinding reference buffer.
  extensions.lua        Frozen event names + listener bus (BUILD_START/OUTPUT/DONE/CANCEL).
  health.lua            :checkhealth msvc.
  util.lua              Path helpers (normalize, join, resolve, basename, ...).
```

## State

The plugin keeps **one** runtime object — the `Msvc` singleton:

| Field                 | Description                                                       |
|-----------------------|-------------------------------------------------------------------|
| `config`              | Merged + validated config table (settings only, no profiles)      |
| `solution`            | Active `.sln` (auto-selected at startup if single in `cwd`, or on `BufEnter *.sln`) |
| `solution_candidates` | All `.sln` files explicitly opened as buffers in this session     |
| `project`             | Optional pinned `.vcxproj`                                        |
| `settings`            | Flat build-settings table for the active context (configuration, platform, arch, vs_version, jobs) |
| `install`             | Last vswhere installation record (with `installationPath`, etc.)  |
| `solution_projects`   | `{ name, path }` parsed from the active `.sln`                    |
| `_context_store`      | In-memory map of `(solution, project)` → flat settings table      |
| `_last_build_key`     | Context key of the most recent `build()` dispatch; `nil` until first build |

## Build settings

Each context key `(solution, project)` stores a **flat settings table** with no profile
indirection. There are no named profiles.

| Field           | Source                                   | Editable in buffer |
|-----------------|------------------------------------------|--------------------|
| `configuration` | Parsed from `.sln` / `.vcxproj`          | Yes (`=` to expand options) |
| `platform`      | Parsed from `.sln` / `.vcxproj`          | Yes |
| `arch`          | Fixed list (x86/x64/arm/arm64)           | Yes |
| `vs_version`    | vswhere installations                    | Yes |
| `jobs`          | Free number; default 6 (or `setup()` override) | Yes |
| `winsdk`        | Auto from `<WindowsTargetPlatformVersion>` in `.vcxproj` | No (hidden) |
| `vcvars_ver`    | Auto from `<PlatformToolset>` in `.vcxproj` | No (hidden) |

Plugin-level config (set once in `setup()`, never in the buffer):
`vswhere_path`, `vs_requires`, `compile_commands`.

## The msvc:// buffer

`:Msvc` with no arguments opens the interactive buffer. Its layout:

```
Solution: /path/to/MySolution.sln   ← read-only label
Target: build                       ← current build type; B/C/R/F/G to switch
Help: h?                            ← read-only label

  configuration  Debug              ← settings fields; = to expand options
  platform       x64
  arch           x64
  vs_version     latest
  jobs           6

────────────────────────────────    ← separator

  ProjectA                          ← - to select / deselect
* ProjectB                          ← selected project
  ProjectC
```

**Keybindings** (active only inside the `msvc://` buffer):

| Key  | Action |
|------|--------|
| `B`  | Set target → `build` (works from any cursor position) |
| `C`  | Set target → `clean` |
| `R`  | Set target → `rebuild` |
| `F`  | Set target → `compile_file` (requires a pinned project and a captured source file) |
| `G`  | Set target → `generate` (compile_commands.json + .clangd only, no build) |
| `l`  | Open log buffer immediately (horizontal split) |
| `x`  | Cancel in-flight build immediately |
| `=`  | Expand / collapse settings field options inline |
| `-`  | On project line: select or deselect as build scope; on settings option: apply value |
| `:w` | Fire current target against active solution + selected project; close buffer; open log |
| `h?` | Open the `msvc-help://` keybinding reference buffer |
| `q`  | Close the buffer without firing |

**Target model:** `B`/`C`/`R`/`F`/`G` switch the `Target:` header value and are not
cursor-sensitive. `:w` always fires against `(msvc.solution, msvc.project, _target)`.
When no project is selected (`msvc.project == nil`), the build targets the full solution.

**Project selection:** `-` on a project line selects it (calls `set_project`). `-` on the
already-selected project clears it (calls `set_project("")`), reverting to full-solution scope.

**Single-file compile (`f`):** requires a `.vcxproj` project to be selected and a source
file captured at buffer-open time. Emits a clear error if either is missing.

## Build lifecycle

1. `:Msvc` → `ui.open()`. Opens the `msvc://` buffer, captures the calling buffer for
   single-file compile, renders the layout from current singleton state.
2. User navigates, adjusts Settings fields with `=` / `-`, stages an action with `B`/`C`/`R`/`F`/`G`.
3. `:w` → resolves the pending `(solution, project)` context, switches via `set_solution()`
   / `set_project()`, then calls `Msvc:build()` / `Msvc:clean()` / `Msvc:rebuild()`.
4. Buffer closes; log buffer opens.
5. `vswhere` → `installationPath` (cached on `Msvc.install`).
6. `DevEnv.find_msbuild(install)` walks `MSBuild\Current\Bin` then
   `MSBuild\15.0\Bin` (with optional `amd64` subdir) until `MSBuild.exe` is found.
7. `DevEnv.resolve(install, arch, vcvars_ver, winsdk)` runs
   `cmd.exe /c "call vcvarsall.bat <args> && echo <sentinel> && set"`
   and parses the resulting environment. Cached per (install, arch, vcvars_ver, winsdk).
8. `Build.spawn` runs MSBuild via `vim.system`.
   stdout / stderr stream through the extension bus to subscribers (live-log buffer, etc.).
9. On exit:
   - On success, `compile_commands.generate` invokes `msbuild-extractor-sample`
     (if installed) under the same env.

## Why MSBuild is not run inside vcvars

MSBuild picks the per-project `<PlatformToolset>` toolset (e.g. v141 for
VS 2017 projects, v143 for VS 2022 projects). Sourcing vcvars before
MSBuild would force a single toolset onto every project in a solution
and break mixed-toolset builds.

The dev-prompt env is still resolved and forwarded so the
`msbuild-extractor-sample` (which uses `MSBuildLocator`) can find
MSBuild and so the compiler / linker can find `INCLUDE` / `LIB` /
`PATH` when invoked outside the dev prompt.

## Cancellation

`taskkill /T /F /PID <msbuild_pid>` (per environment policy: PID-based,
never name-based). `/nr:false` is always passed to MSBuild itself so
worker nodes do not survive parent termination.

## Context keys

The pair `(solution, project)` — where either may be `nil` — forms a **context key**.
Every call to `set_solution()` or `set_project()` saves the current flat settings table
for the outgoing key and restores the stored settings for the incoming key. A key that
has never been seen initialises from plugin defaults with empty settings.

Context state is in-memory only and does not survive Neovim restarts.

## Solution population

Solutions enter `solution_candidates` in exactly two ways — no background scanning, no git traversal:

1. **Startup single-sln check** — `setup()` does a shallow `glob(cwd .. "/*.sln")`. If exactly one `.sln` is found, it is added to `solution_candidates` and immediately selected via `set_solution()`.
2. **`BufEnter *.sln`** — whenever the user opens a `.sln` buffer (directly or via netrw), the path is appended to `solution_candidates` (deduped, sorted) and `set_solution()` is called unconditionally, making it the active solution and clearing any pinned project.

No other mechanism populates candidates. If the user opens nvim in a directory with multiple `.sln` files, no solution is pre-selected; they open one directly.
