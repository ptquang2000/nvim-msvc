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
  discover.lua          Walk-up to find .sln; parse its projects + their (config, platform).
  compile_commands.lua  Drive msbuild-extractor-sample after a successful build.
  quickfix.lua          Parse MSBuild output through Vim's errorformat.
  log.lua               vim.notify wrapper + live-tail buffer for build output.
  extensions.lua        Frozen event names + listener bus (BUILD_START/OUTPUT/DONE/CANCEL).
  health.lua            :checkhealth msvc.
  util.lua              Path helpers (normalize, join, resolve, basename, ...).
```

## State

The plugin keeps **one** runtime object — the `Msvc` singleton:

| Field               | Description                                                       |
|---------------------|-------------------------------------------------------------------|
| `config`            | Merged + validated config table                                   |
| `solution`          | Auto-discovered `.sln` (walk-up from cwd)                         |
| `project`           | Optional pinned `.vcxproj`                                        |
| `profile_name`      | Active profile name                                               |
| `install`           | Last vswhere installation record (with `installationPath`, etc.)  |
| `overrides`         | Per-session profile-field overrides set via `:Msvc update`        |
| `solution_projects` | `{ name, path }` parsed from the active `.sln`                    |

## Build lifecycle

1. `:Msvc build [target]` → `Msvc:build()`.
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

## Auto-completion sources

- `configuration` / `platform` — parsed from the active `.sln`'s
  `GlobalSection(SolutionConfigurationPlatforms)` and from any pinned
  `.vcxproj`.
- `vs_version` / `vs_products` — `vswhere -all -prerelease`.
- `vcvars_ver` — directories under `<install>\VC\Tools\MSVC\`.
- `winsdk` — directories under `Windows Kits\10\Include\10.0.*`.
- `profile` — `config.profiles` keys.
