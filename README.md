# nvim-msvc

A **Windows-only** Neovim plugin that wraps `MSBuild.exe` and the MSVC
developer environment (`vswhere.exe`, `vcvarsall.bat`, `cl.exe`, `link.exe`,
`INCLUDE`, `LIB`, …) into a first-class async build workflow with quickfix
streaming, solution / project discovery, and cancellable jobs.

## Requirements

- **Windows** (the plugin is Windows-only; PowerShell is the dev tooling).
- **Neovim ≥ 0.10** (uses `vim.system` for async jobs).
- **Visual Studio 2019 or 2022** with the **Desktop development with C++**
  workload installed, providing the **VC++ x64 build tools** (component id
  `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`) and `MSBuild.exe`.
- **`vswhere.exe`** is optional but strongly recommended; without it the
  plugin falls back to `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer`.
  Visual Studio 2017 Update 2+ ships `vswhere` automatically.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "quangphan/nvim-msvc",
    cond = function() return vim.fn.has("win32") == 1 end,
    ft = { "c", "cpp", "cs" },
    cmd = "Msvc",
    config = function()
        require("msvc").setup({})
    end,
}
```

## Quickstart

```lua
require("msvc").setup({})
```

Then, inside any directory containing a `.sln` or `.vcxproj`:

```vim
:Msvc profile debug_x64
:Msvc build
```

`:Msvc build` requires an active profile. `:Msvc compile` and `:Msvc
generate` require an active resolve. If `settings.use_dev_env = true`,
`:Msvc build` additionally requires an active resolve (the dev env is
sourced from it).

`:Msvc build` will auto-discover the solution, resolve the MSVC dev
environment from the active resolve, spawn `MSBuild.exe` asynchronously,
stream output to the build-log buffer, and publish errors/warnings to the
quickfix list.

## Configuration

The full default schema (extracted from `lua/msvc/config.lua`):

```lua
require("msvc").setup({
    settings = {
        notify_level    = vim.log.levels.INFO, -- min level for vim.notify()
        echo_command    = false,               -- echo the MSBuild cmdline before spawn
        build_on_save   = false,               -- BufWritePost autocmd triggers :Msvc build
        open_quickfix   = true,                -- :copen after a failed build
        qf_height       = 10,                  -- height of the quickfix split
        auto_select_sln = true,                -- auto-pin the lone .sln in cwd on setup
        search_depth    = 4,                   -- recursion depth for sln/vcxproj discovery
        cache_env       = true,                -- persist resolved dev env across sessions
        env_cache_path  = vim.fn.stdpath("cache") .. "/nvim-msvc-env.json",
        last_log_path   = vim.fn.stdpath("cache") .. "/nvim-msvc-last.log",
        use_dev_env     = false,               -- source VsDevCmd/vcvarsall before MSBuild
        on_build_start  = nil,                 -- fun(ctx)        — back-compat shim
        on_build_done   = nil,                 -- fun(ctx, ok, ms) — back-compat shim
        on_build_cancel = nil,                 -- fun(ctx)        — back-compat shim
    },
    -- Defaults inherited by every named profile *and* every named resolve
    -- (named entries override these per-key with vim.tbl_extend("force")).
    default = {
        vs_version       = "latest",           -- vswhere -version filter ("latest"|"16"|"17"|...)
        vs_prerelease    = false,              -- include preview channel installs
        vs_products = {                        -- vswhere -products filter
            "Microsoft.VisualStudio.Product.Community",
            "Microsoft.VisualStudio.Product.Professional",
            "Microsoft.VisualStudio.Product.Enterprise",
            "Microsoft.VisualStudio.Product.BuildTools",
        },
        vs_requires = {                        -- vswhere -requires filter
            "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        },
        vswhere_path     = nil,                -- explicit path; nil = auto-detect
        arch             = "x64",              -- target arch for vcvarsall (x64/x86/arm64)
        host_arch        = "x64",              -- host arch for vcvarsall
        msbuild_args     = { "/nologo", "/v:minimal" }, -- always-on MSBuild args
        jobs             = 0,                  -- /m:N   (0 = MSBuild default)
    },

    -- Named *resolves*: select one at runtime via `:Msvc resolve <name>`.
    -- A resolve holds the parameters passed to VsDevCmd.bat / vcvarsall.bat
    -- and to vswhere when locating the VS install.
    resolves = {
        dev = {
            arch       = "x64",                -- target arch
            host_arch  = "x64",                -- host arch
            -- vcvars_ver = "14.39",            -- pin a specific toolset (optional)
        },
        arm64_dev = {
            arch       = "arm64",
            host_arch  = "x64",
        },
        buildtools = {
            -- restrict vswhere to a Build Tools install
            vs_products = { "Microsoft.VisualStudio.Product.BuildTools" },
            arch        = "x64",
        },
    },

    -- Named *profiles*: select one at runtime via `:Msvc profile <name>`.
    -- A profile holds MSBuild parameters (configuration / platform / target
    -- / msbuild_args / jobs ...). Any top-level key that is not `settings`,
    -- `default`, or `resolves` is treated as a profile name.
    debug_x64 = {
        configuration = "Debug",               -- /p:Configuration=
        platform      = "x64",                 -- /p:Platform=
        jobs          = 0,                     -- /m:N
    },
    release_x64 = {
        configuration = "Release",
        platform      = "x64",
        msbuild_args  = { "/nologo", "/v:minimal", "/p:RunCodeAnalysis=false" },
    },
    arm64_release = {
        configuration = "Release",
        platform      = "ARM64",
    },
})
```

Activate a profile before building. `:Msvc compile` / `:Msvc generate`
additionally need an active resolve:

```vim
:Msvc profile debug_x64
:Msvc build
:Msvc resolve dev
:Msvc generate
```

On the first `setup()` call the alphabetically-first user-defined
profile and resolve are auto-selected when nothing is active yet, so
typical setups don't need an explicit `:Msvc profile` / `:Msvc resolve`
to get going. `setup()` also kicks off an asynchronous `vswhere` lookup
to populate `state.install_path` in the background — `setup()` returns
immediately and the path is filled in by the time you trigger a build.
Configured `install_path` values (on `default` or the active resolve)
short-circuit the lookup.

Merging uses `vim.tbl_extend("force", ...)` — **never recursive**, so array values
(`vs_products`, `msbuild_args`, …) are replaced wholesale.

## Commands

All commands are dispatched through a single `:Msvc <subcommand>` (modeled on
`:Telescope` / `:Lazy`):

- `:Msvc build [target]` — Build the active solution. If a project has
  been pinned via `:Msvc project <name>`, builds that `.vcxproj` instead
  (with `/p:SolutionDir=<sln-dir>\` so `$(SolutionDir)`-relative paths
  still resolve). Optional MSBuild target: `Build` / `Rebuild` / `Clean`.
  Requires an active profile. If `settings.use_dev_env = true`, also
  requires an active resolve (the dev env is sourced from it).
- `:Msvc rebuild` — Run MSBuild with `target=Rebuild`.
- `:Msvc clean` — Run MSBuild with `target=Clean`.
- `:Msvc cancel` — Cancel the in-flight MSBuild invocation
  (`taskkill /T /F /PID …`).
- `:Msvc status` — Echo solution / project / profile / resolve / install
  snapshot.
- `:Msvc log` — Open the in-memory plugin log buffer.
- `:Msvc build_log` — Open the captured MSBuild output buffer.
- `:Msvc profile <name>` — Set (or show) the active named profile from
  config. Profile entries hold MSBuild settings (`configuration`,
  `platform`, `target`, `msbuild_args`, `jobs`, ...).
- `:Msvc resolve <name>` — Set (or show) the active named resolve from
  `config.resolves`. Resolve entries hold developer-env parameters
  (`arch`, `host_arch`, `vcvars_ver`, `vs_*`, `vswhere_path`,
  `install_path`).
- `:Msvc update <property> <value>` — Override a single property on the
  active profile or resolve. Property name selects the target: profile
  properties (`configuration`, `platform`, `target`, `verbosity`,
  `msbuild_args`, `jobs`, `max_cpu_count`, `no_logo`, `extra_args`)
  update the active profile;
  resolve properties (`arch`, `host_arch`, `vcvars_ver`, `vs_version`,
  `vs_prerelease`, `vs_products`, `vs_requires`, `vswhere_path`) update
  the active resolve. `install_path` is a global runtime state value
  (no profile or resolve selection required) and is updated directly on
  the active state. Booleans accept
  `true`/`false`/`1`/`0`/`yes`/`no`. Tables accept comma-separated values.
  Both arguments are tab-completed (property names and known enums).
  Overrides are **transient** — they live on top of the configured
  baseline and are cleared whenever the corresponding profile or
  resolve is re-selected via `:Msvc profile` / `:Msvc resolve`.
- `:Msvc project [name]` — Pin a single project (subset of the loaded
  solution) so subsequent builds target only that `.vcxproj`. Tab
  completion lists the project names parsed from the active `.sln`
  during setup. Pass no argument (or the synthetic `<solution>`) to
  clear the selection and have `:Msvc build` target the full solution
  again.
- `:Msvc discover` — Re-scan cwd for the parent `.sln` and refresh the
  cached project list. Useful when you `:cd` into a different repo
  during the same Neovim session.
- `:Msvc health` — Run `:checkhealth msvc`.
- `:Msvc compile` — Compile the current buffer's source file (placeholder
  hook; logs a warning until `Msvc:compile_current_file` lands). Requires
  an active resolve.
- `:Msvc generate` — Generate `compile_commands.json` (placeholder hook;
  logs a warning until `Msvc:generate_compile_commands` lands). Requires
  an active resolve.
- `:Msvc help` — List every `:Msvc` subcommand.

## Events

`require("msvc.extensions").extensions:add_listener({ ... })` accepts a
listener table whose keys are `event_names` (frozen). Payloads:

| Event            | Payload                                            | Emitted from        |
|------------------|----------------------------------------------------|---------------------|
| `BUILD_START`    | `(ctx: MsvcBuildContext)`                          | `MsvcBuild:start`   |
| `BUILD_OUTPUT`   | `(ctx, line: string, stream: "stdout"\|"stderr")`  | `MsvcBuild` job pipe|
| `BUILD_DONE`     | `(ctx, ok: boolean, elapsed_ms: integer)`          | `MsvcBuild:_finish` |
| `BUILD_CANCEL`   | `(ctx)`                                            | `MsvcBuild:cancel`  |
| `ENV_RESOLVED`   | `(env: MsvcDevEnv)`                                | `devenv.resolve`    |
| `STATE_CHANGED`  | `(field: string, old, new)`                        | `MsvcState`         |

```lua
local Ext = require("msvc.extensions")
Ext.extensions:add_listener({
    [Ext.event_names.BUILD_DONE] = function(ctx, ok, ms)
        vim.notify(("build %s in %d ms"):format(ok and "OK" or "FAILED", ms))
    end,
})
```

## Lua API

`require("msvc")` returns the `Msvc` singleton. Public methods:

- `msvc:setup(partial_config?)` — Idempotent; merges config, registers
  autocmds, wires back-compat callback shims.
- `msvc:build(opts?)` — Async MSBuild; `opts.target` selects
  `Build`/`Rebuild`/`Clean`. Returns the `MsvcBuild` instance.
- `msvc:cancel_build()` — Cancel the in-flight build, if any.
- `msvc:resolve(opts?)` — Resolve & cache the MSVC dev env from the
  active named resolve in `config.resolves`; `opts.name` overrides the
  active resolve, `opts.arch` overrides its arch.
- `msvc:status()` — Echo solution/project/profile/resolve/install snapshot.
- `msvc:set_profile(name)` — Switch the active named profile.
- `msvc:set_resolve(name)` — Switch the active named resolve.
- `msvc:set_project(name_or_path)` — Pin a project from the cached
  `solution_projects` (or by `.vcxproj` path); pass `nil` to clear.
- `msvc:auto_discover()` — Re-scan cwd for the parent `.sln` and refresh
  the cached project list; returns the pinned solution path.
- `msvc:show_log()` / `msvc:show_build_log()` — Open the plugin and MSBuild
  log buffers.

## Architecture

Module-returns-singleton in `init.lua`; class-style modules with metatables
for stateful pieces (`Msvc`, `MsvcLog`, `MsvcState`, `MsvcBuild`,
`MsvcExtensions`); layered config (`settings` / `default` / `[profile]`)
merged non-recursively with `vim.tbl_extend("force", …)`; named-event bus
(`MsvcExtensions:emit`) replacing ad-hoc callbacks; one shared `:Msvc`
dispatcher with subcommand tab-completion replacing the old per-verb
`:MS*` commands.

## Development (Windows)

Tooling is PowerShell — there is intentionally no Makefile, justfile, or
shell script. From the repository root:

```powershell
./scripts/format.ps1   # stylua over lua/ and tests/
./scripts/lint.ps1     # luacheck over lua/ and tests/
./scripts/test.ps1     # plenary-busted headless tests
./scripts/check.ps1    # format-check + lint + test (CI-equivalent)
```

Run `./scripts/check.ps1` before sending a PR; it must exit 0.

## Troubleshooting

- **`vswhere.exe not found`** — Either install Visual Studio 2017 Update 2+
  (which ships `vswhere`), or set `default.vswhere_path` in `setup` to an
  explicit path. The fallback search location is
  `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe`.
- **`MSBuild.exe not found`** — Confirm the **Desktop development with C++**
  workload is installed and the resolved install matches `vs_version` /
  `vs_products` / `vs_requires`. Run `:Msvc resolve <name>` then
  `:Msvc status` to inspect what was discovered, or `:Msvc log` for the
  full trace.
- **Cancelled build leaves orphan `cl.exe` / `link.exe` processes** —
  `:Msvc cancel` invokes `taskkill /T /F /PID <msbuild-pid>` which kills the
  whole tree. If a runaway compiler survives (e.g. because MSBuild had
  already detached it), kill it manually with
  `taskkill /T /F /PID <pid>` — never `Stop-Process -Name` (it can match
  unrelated processes).

## License

MIT — see [LICENSE](LICENSE).
