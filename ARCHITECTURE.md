# nvim-msvc — Architecture

This document describes the internal layout of the plugin: the modules
under `lua/msvc/`, how they collaborate, and the data that flows between
them. It is meant for contributors; user-facing docs live in
[`README.md`](README.md) and [`doc/msvc.txt`](doc/msvc.txt).

## High-level shape

- **One singleton entry point.** `require("msvc")` returns a single
  `Msvc` instance constructed in `init.lua`. There is no factory and no
  per-buffer state — solution / project / profile selection is global
  to the Neovim session.
- **Layered, non-recursive config.** A `MsvcConfig` is the merge of
  `settings`, the configured root profile (named by
  `settings.default_profile`, required), and the active named profile.
  Profiles are flat: MSBuild parameters (`configuration`, `platform`,
  `target`, `msbuild_args`, …) and dev-env parameters (`arch`,
  `host_arch`, `vcvars_ver`, `winsdk`, `vs_*`, …) live side by side
  on the same table — subsystems pick the keys they care about.
  Merging always uses `vim.tbl_extend("force", ...)` so array values
  (`vs_products`, `msbuild_args`, …) are replaced wholesale rather
  than concatenated.
- **Class-style modules with metatables** for stateful pieces
  (`Msvc`, `MsvcLog`, `MsvcState`, `MsvcBuild`, `MsvcExtensions`).
  Pure-helper modules (`util`, `discover`, `quickfix`, `vswhere`,
  `devenv`, `config`) just return tables of functions.
- **Named-event bus** in `extensions.lua` replaces ad-hoc callbacks.
  Listeners are tables keyed by frozen event names; the bus catches
  per-listener errors with `pcall` so one broken listener never blocks
  the rest.
- **One user-command, many subcommands.** `:Msvc <sub>` dispatches
  through `commands.lua`, modeled on `:Telescope` / `:Lazy`. Tab
  completion is per-subcommand.

## Module map

```
plugin/msvc.lua              Loads the plugin on Neovim startup
└── lua/msvc/
    ├── init.lua             Msvc singleton: lifecycle, public API
    ├── config.lua           Schema, merge, validation, formatting
    ├── state.lua            MsvcState (solution/project/profile/install/arch)
    ├── commands.lua         :Msvc <sub> dispatcher and tab-completion
    ├── autocmd.lua          Shared augroup ("MsvcAugroup")
    ├── extensions.lua       MsvcExtensions event bus + frozen event_names
    ├── log.lua              MsvcLog ring buffer + vim.notify routing
    ├── build.lua            MsvcBuild: async MSBuild job, output streaming
    ├── compile_commands.lua Wraps msbuild-extractor-sample for compile_commands.json
    ├── devenv.lua           vcvarsall / VsDevCmd resolution + env caching
    ├── discover.lua         .sln / .vcxproj walk-up discovery
    ├── vswhere.lua          vswhere.exe wrapper, install lookup, async warm
    ├── quickfix.lua         MSBuild / cl.exe / link.exe efm + parse_lines
    └── util.lua             Path, table, string, shell-quote helpers
```

## Module responsibilities

### `init.lua` — `Msvc` singleton
The orchestration layer. Holds the merged `config`, the `state`
instance, the `extensions` bus, and the in-flight `current_build`. It
exposes the public Lua API (`setup`, `build`, `cancel_build`, `resolve`,
`status`, `set_profile`, `set_project`, `auto_discover`) and owns the
**transient override table**
`profile_overrides[name]`, keyed by profile name and cleared
whenever the profile is re-selected.

### `config.lua` — schema, merging, validation
Pure module. Defines `MsvcConfig`, `MsvcSettings`, `MsvcProfileItem`,
and `KNOWN_PROFILE` (which fields a profile may carry — both MSBuild
and dev-env keys). Public functions:
- `Config.merge_config(partial)` — layer the user input over defaults.
- `Config.get_profile(config, name)` — return the effective flat
  profile view (engine defaults ⨉ root profile named by
  `settings.default_profile` ⨉ `profiles[name]`).
- `Config.validate(config)` — type-check fields against
  `KNOWN_SETTINGS` / `KNOWN_PROFILE`; collect a list of error strings.
- `Config.format_entry_lines(header, tbl)` — render `key = value`
  lines for verbose `:Msvc profile` / `status` output.

### `state.lua` — `MsvcState`
A small wrapper around eight fields: `solution`, `project`, `profile`,
`install_path`, `install_display_name`, `install_version`,
`install_product_line_version`, `arch`. **`install_path` is a runtime
state cache only** — it is populated automatically by the async
`vswhere` warm and is no longer a user-facing config field. The three
`install_*` companions (`install_display_name`, `install_version`,
`install_product_line_version`) are an atomic write group: every site
that writes `install_path` writes them too, every site that clears
`install_path` clears them. They are consumed only by `:Msvc status`
to render the friendly install line. Mutators emit `STATE_CHANGED` on
the bus; unknown fields raise on assignment via `ALLOWED_FIELDS`.
`get_snapshot()` returns a flat snapshot for `:Msvc status`.

### `commands.lua` — dispatcher
The user-facing surface. Each entry in `subcommands` is
`{ impl, complete, desc }`. The dispatcher and completion are wired
into `:Msvc` via a single `nvim_create_user_command`. `commands.lua`
is the only module that calls into `Msvc:set_profile` / `Msvc:build`
on user intent — the rest of the codebase never touches Neovim
ex-commands.

### `build.lua` — `MsvcBuild`
Wraps `vim.system()` for MSBuild. Owns the build context (`project`,
`configuration`, `platform`, `target`, `verbosity`, `max_cpu_count`,
`no_logo`, `extra_args`), spawns the job, fans line-by-line stdout /
stderr through `BUILD_OUTPUT`, parses the captured log into a quickfix
list on completion, and emits `BUILD_START` / `BUILD_DONE` /
`BUILD_CANCEL`. Cancellation invokes
`taskkill /T /F /PID <msbuild-pid>` so the entire compiler tree dies
with the parent — never name-based killers.

### `devenv.lua` — vcvarsall resolution
Spawns `vcvarsall.bat` (or `VsDevCmd.bat`) in a subshell with `set` and
parses the resulting environment, filtered by `ENV_WHITELIST`
(`PATH`, `INCLUDE`, `LIB`, `LIBPATH`, `VCINSTALLDIR`, …). Output is
optionally cached to disk (`settings.env_cache_path`) keyed by the
resolved (`install_path`, `arch`, `host_arch`, `vcvars_ver`, `winsdk`,
`vcvars_spectre_libs`) tuple. Emits `ENV_RESOLVED` on success.
`VCToolsVersion` / `VCToolsInstallDir` / `VCToolsRedistDir` are
intentionally **not** propagated — vcvars exports the *latest*
toolset values, which conflict with a pinned `vcvars_ver`.

### `discover.lua` — solution discovery
Pure walk-up search starting from cwd, bounded by
`settings.search_depth` and a `DEFAULT_IGNORE_DIRS` blocklist
(`.git`, `node_modules`, `obj`, `bin`, `x64`, `Debug`, `Release`,
…). Returns the `.sln` path plus any `.vcxproj` siblings parsed out
of the solution file.

### `vswhere.lua` — VS install lookup
Wraps `vswhere.exe`. Filters by `vs_version`, `vs_prerelease`,
`vs_products`, `vs_requires` (from the merged profile view) and
returns an `installationPath`. User-facing `vs_version` shorthands
(`"2017"`, `"17"`, …) are translated to vswhere's range syntax via
`translate_version` before being passed to the executable — vswhere
itself does NOT understand the marketing-year tokens. Falls back to
`%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe`
when no explicit `vswhere_path` is configured. Called asynchronously
during `setup()` as **two independent parallel calls**:

  1. **Unfiltered warm** — passes no `vs_version` / `vs_products` /
     `vs_requires` and forces `vs_prerelease=true` /
     `include_packages=true`. Drives the `vs_completion_candidates`
     table on the singleton, so `:Msvc update <vs_*> <Tab>` lists
     every install on the machine regardless of the active profile
     filters (the original "menu shrinks after selection" bug).
  2. **Filtered resolve** — uses the active profile filters and
     populates `state.install_path` plus the friendly metadata
     (`install_display_name`, `install_version`,
     `install_product_line_version`). Skipped when `install_path` is
     already cached.

The two calls write to disjoint state targets and fail independently —
a failing unfiltered warm leaves completion candidates empty (the
static fallback in `commands.lua` covers the gap); a failing filtered
resolve leaves `install_path` nil. The `vs_version` candidate list is
strict: `"latest"`, every install's full `installationVersion`, and
the canonical major-range string `"[N.0,(N+1).0)"` per unique major.
Marketing-year and bare-major shorthands are deliberately not
suggested — they remain valid freehand input via `translate_version`.

The project-scan-derived `project_targets` cache that feeds
`configuration` / `platform` completion runs in parallel as a third
warm.

When the user runs `:Msvc update vs_version <X>` (or any `vs_*` /
`vswhere_path` field), the override is written through
`profile_overrides[name]` AND `state.install_path` is invalidated and
re-resolved synchronously (via `Msvc:_resolve_install_path_sync`) so
the immediate `:Msvc status` reflects the new selection. The async
warm is also re-kicked to refresh the completion candidates. If no
install matches, `state.install_path` stays nil and a `Log:warn` names
the offending `vs_version`.

### `quickfix.lua` — error parsing
Defines the MSBuild / `cl.exe` / `link.exe` `errorformat` string and
`parse_lines(lines) -> QfEntry[]`. The build pipeline streams output
through this module after MSBuild exits; errors and warnings are
published to a project-local quickfix list.

### `compile_commands.lua` — clang DB extractor wrapper
Pure module that wraps the upstream
[`microsoft/msbuild-extractor-sample`](https://github.com/microsoft/msbuild-extractor-sample)
tool. The binary name (`msbuild-extractor-sample`) is **implicit**: the
module probes `PATH` via `vim.fn.exepath` (cached on the module) and
treats discovery the same way `nvim-treesitter` treats the
`tree-sitter` CLI — present means the integration is active, missing
means a one-time warning is logged and the build itself is unaffected.
`init.lua` installs a `BUILD_DONE` listener during `setup()` that, on
success, calls `CompileCommands.generate({ solution, project,
configuration, platform, cc = settings.compile_commands })`. The module
spawns the tool asynchronously via `vim.system`, composes
`--solution` / `--project` / `-c` / `-a` / `-o` / `--merge` /
`--deduplicate` from the merged settings, and (when
`settings.compile_commands.builddir` is set) feeds every `*.vcxproj`
discovered recursively under that directory as an extra `--project`
input so the resulting `compile_commands.json` covers both the in-tree
solution and any out-of-source projects. The builddir scan filters out
CMake VS-generator meta-targets (`ALL_BUILD`, `ZERO_CHECK`, `INSTALL`,
`PACKAGE`, `RUN_TESTS`, `RESTORE`, and CTest dashboard targets) by
case-insensitive basename match.

### `extensions.lua` — event bus
Singleton `MsvcExtensions` plus a frozen `event_names` table. Listeners
are plain tables keyed by event name; `:add_listener({ ... })` returns
a handle for `:remove_listener`. Errors in one listener are reported
via `vim.notify` and never bubble up.

### `log.lua` — `MsvcLog`
Ring-buffer log (`max_lines`, default 5000) shared across the plugin.
Routes to `vim.notify` when a message exceeds `settings.notify_level`
and owns the persistent live build-log buffer (`msvc://live-build-log`)
that backs `:Msvc log` — it streams MSBuild output while a build is
running and retains the last build's transcript when idle.

### `autocmd.lua` — shared augroup
Returns the `MsvcAugroup` augroup id. Every autocmd in the plugin
(`BufWritePost` for `build_on_save`, `VimLeavePre` for env-cache flush,
…) is registered against this group so `setup()` can re-clear them
idempotently.

### `util.lua` — shared helpers
Pure functions: path join / normalize / basename / dirname /
extension, `tbl_deep_merge`, `shell_escape` (CommandLineToArgvW
quoting), `is_windows`, etc. No side effects at require time.

## Data flow — a build

```
:Msvc build [target]
   │
   ▼
commands.subcommands.build.impl
   │  require_profile()
   ▼
Msvc:build(opts)
   │  resolve effective profile view via Config.get_profile,
   │  layered over profile_overrides[name]
   │  resolve_install_path() (no VsDevCmd sourcing for the build env
   │  so per-project <PlatformToolset> toolsets aren't pinned)
   ▼
MsvcBuild:start(ctx)
   │  spawn MSBuild via vim.system, stream stdout/stderr
   │  ── BUILD_START ──▶  ── BUILD_OUTPUT ──▶
   ▼
on exit
   │  QuickFix.parse_lines(captured) → vim.fn.setqflist
   │  ── BUILD_DONE ──▶
   ▼
status logged, qf opened on failure
```

## Concurrency & lifetime

- **Single in-flight build.** `Msvc.current_build` is the live job.
  Starting a new build while another is running cancels the previous
  one (`Msvc:cancel_build`) before spawning. There is no build queue.
- **`setup()` is idempotent.** Calling it multiple times re-merges the
  config layer, re-clears the augroup, and re-installs autocmds. It
  also kicks off two parallel `vswhere` warms (an unfiltered warm
  populating the `vs_*` completion candidate lists, and a filtered
  resolve populating `state.install_path` plus the friendly metadata
  `install_display_name` / `install_version` /
  `install_product_line_version`) and a project scan (populates the
  `configuration` / `platform` candidate lists from the active
  solution's `.sln` + `.vcxproj` files). `setup()` returns
  immediately; all warms fill in before the first build.
- **No coroutines.** All asynchrony goes through `vim.system()` or
  `vim.uv` callbacks. There is intentionally no `vim.loop`-driven
  event loop and no plenary `co.wrap`.

## Config layering — recap

| When                  | Final view                                                                                    |
|-----------------------|-----------------------------------------------------------------------------------------------|
| Any profile field     | `engine defaults` → `profiles[settings.default_profile]` → `profiles[name]` → `profile_overrides[name]` |

`settings.default_profile` is **required** and names the *root* profile
that contributes to every named view; other named profiles are
isolated from each other and merged on top. Engine defaults
(`vs_products`, `arch`, `msbuild_args`, …) live in an internal
`INTERNAL_DEFAULTS` table inside `config.lua` so users only need to
declare fields they want to override. MSBuild parameters
(`configuration`, `platform`, `msbuild_args`, …) and dev-env parameters
(`arch`, `host_arch`, `vcvars_ver`, `winsdk`, `vs_*`, …) all live on
the same flat table — there is no schema-level partitioning.
Subsystems read the keys they care about.

## Testing

`scripts/test.ps1` runs `plenary-busted` headless against
`lua/msvc/test/`. Specs are pure-Lua and stub Neovim primitives only
when needed (e.g. `vim.notify` is silenced via `MsvcLog:set_level`).
The CI-equivalent gate is `scripts/check.ps1` (format-check + lint +
test); contributors should run it before sending a PR.
