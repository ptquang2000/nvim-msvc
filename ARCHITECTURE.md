# Architecture

`nvim-msvc` is intentionally small. The whole plugin is a single
singleton (`require('msvc')`) plus a handful of stateless helper modules.

## Module layout

```
lua/msvc/
  init.lua              The Msvc singleton + setup() entry point.
  config.lua            Schema, merge, validate. Two layers: settings + default + profiles.
  commands.lua          :Msvc subcommand dispatcher and tab-completion.
  build.lua             Spawn MSBuild via vim.system; cancel via taskkill /T /F /PID.
  devenv.lua            Run vcvarsall.bat in cmd.exe; cache the resulting env.
  vswhere.lua           JSON wrapper around vswhere.exe (sync + async).
  discover.lua          Parse .sln projects and configuration/platform targets; shallow single-sln startup scan.
  compile_commands.lua  Drive msbuild-extractor-sample after a successful build.
  quickfix.lua          Parse MSBuild output through Vim's errorformat.
  log.lua               vim.notify wrapper + live-tail buffer for build output.
  extensions.lua        Frozen event names + listener bus (BUILD_START/OUTPUT/DONE/CANCEL).
  health.lua            :checkhealth msvc.
  util.lua              Path helpers (normalize, join, resolve, basename, ...).
```

## State

The plugin keeps **one** runtime object — the `Msvc` singleton:

| Field                 | Description                                                       |
|-----------------------|-------------------------------------------------------------------|
| `config`              | Merged + validated config table                                   |
| `solution`            | Active `.sln` (auto-selected at startup if single in `cwd`, or on `BufEnter *.sln`, or via `:Msvc solution`) |
| `solution_candidates` | All `.sln` files explicitly opened as buffers in this session     |
| `project`             | Optional pinned `.vcxproj`                                        |
| `profile_name`        | Active profile name (scoped to the current context key)           |
| `install`             | Last vswhere installation record (with `installationPath`, etc.)  |
| `overrides`           | Profile-field overrides for the current context key, set via `:Msvc update` |
| `solution_projects`   | `{ name, path }` parsed from the active `.sln`                    |
| `_context_store`      | In-memory map of `(solution, project)` → `{ profile_name, overrides }` |
| `_last_build_key`     | Context key of the most recent successful `build()` dispatch; `nil` until first build |

## Build lifecycle

1. `:Msvc build [context-label]` → `Msvc:build()`. If a context label is supplied, the plugin switches to that `(solution, project)` context before building. Tab-completion lists all known context keys (from `_context_store`) with `_last_build_key` first.
2. Resolve the active profile (named entry shallow-merged over `default`).
3. `vswhere` → `installationPath` (cached on `Msvc.install`).
4. `DevEnv.find_msbuild(install)` walks `MSBuild\Current\Bin` then
   `MSBuild\15.0\Bin` (with optional `amd64` subdir) until `MSBuild.exe`
   is found.
5. `DevEnv.resolve(install, arch, vcvars_ver, winsdk)` runs
   `cmd.exe /c "call vcvarsall.bat <args> && echo <sentinel> && set"`
   and parses the resulting environment. Cached per (install, arch,
   vcvars_ver, winsdk).
6. `Build.spawn` runs MSBuild via `vim.system` with the env from #5.
   stdout / stderr stream through the extension bus to subscribers
   (live-log buffer, etc.).
7. On exit:
   - Output is parsed through Vim's `errorformat` and published as a
     quickfix list.
   - On success, `compile_commands.generate` invokes
     `msbuild-extractor-sample` (if installed) under the same env.

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

The pair `(solution, project)` — where either may be `nil` — forms a **context key**. Every call to `set_solution()` or `set_project()` (including `BufEnter *.sln` auto-selection) saves `{ profile_name, overrides }` for the outgoing key and restores the stored state for the incoming key. A key that has never been seen initialises from `settings.default_profile` with empty overrides.

Calling `:Msvc profile <name>` or `:Msvc update <field> <value>` mutates the live `profile_name` / `overrides` directly; that state is persisted to `_context_store` automatically on the next key transition. Context state is in-memory only and does not survive Neovim restarts.

## Solution population

Solutions enter `solution_candidates` in exactly two ways — no background scanning, no git traversal:

1. **Startup single-sln check** — `setup()` does a shallow `glob(cwd .. "/*.sln")`. If exactly one `.sln` is found, it is added to `solution_candidates` and immediately selected via `set_solution()`.
2. **`BufEnter *.sln`** — whenever the user opens a `.sln` buffer (directly or via netrw), the path is appended to `solution_candidates` (deduped, sorted) and `set_solution()` is called unconditionally, making it the active solution and clearing any pinned project.

No other mechanism populates candidates. If the user opens nvim in a directory with multiple `.sln` files, no solution is pre-selected; they open one directly or use `:Msvc solution <path>`.

## Auto-completion sources

- `build` (context label) — all `(solution, project)` pairs from `_context_store`, with `_last_build_key` first.
- `configuration` / `platform` — parsed from the active `.sln`'s
  `GlobalSection(SolutionConfigurationPlatforms)` and from any pinned
  `.vcxproj`.
- `vs_version` / `vs_products` — `vswhere -all -prerelease`.
- `vcvars_ver` — directories under `<install>\VC\Tools\MSVC\`.
- `winsdk` — directories under `Windows Kits\10\Include\10.0.*`.
- `profile` — `config.profiles` keys.
