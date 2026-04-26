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

`:Msvc build` and `:Msvc compile` both require an active profile. The
profile's dev-env fields (`arch`, `host_arch`, `vcvars_ver`, `winsdk`,
`vs_*`, …) supply the dev env when needed. The compile_commands
extractor always receives a fully-resolved developer-prompt env so
MSBuildLocator can find MSBuild without a standalone .NET SDK.

`:Msvc build` will auto-discover the solution, resolve the MSVC dev
environment from the active profile, spawn `MSBuild.exe`
asynchronously, stream output to the build-log buffer, and publish
errors/warnings to the quickfix list.

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
        default_profile = "base",              -- REQUIRED: name of root profile (must be a key under `profiles`)
        on_build_start  = nil,                 -- fun(ctx)        — back-compat shim
        on_build_done   = nil,                 -- fun(ctx, ok, ms) — back-compat shim
        on_build_cancel = nil,                 -- fun(ctx)        — back-compat shim

        -- compile_commands.json generation via the upstream
        -- microsoft/msbuild-extractor-sample tool. The
        -- `msbuild-extractor-sample` executable must be on PATH (matches
        -- nvim-treesitter's `tree-sitter` CLI model — the binary is
        -- implicit and not configurable). When found, it is invoked
        -- automatically after every successful `:Msvc build`; when
        -- missing, the build still succeeds and a one-time warning is
        -- logged.
        compile_commands = {
            enabled    = true,                 -- auto-run after a successful build
            outdir     = nil,                  -- output dir for compile_commands.json
                                               --   (defaults to the .sln's directory;
                                               --    relative paths resolve to sln/proj/cwd)
            builddir   = nil,                  -- if set, recursively scan for *.vcxproj
                                               --   under it and merge into the main file
                                               --   (relative paths resolve to sln/proj/cwd)
            merge      = true,                 -- pass --merge to the extractor
            deduplicate = true,                -- pass --deduplicate to the extractor
            extra_args = nil,                  -- extra extractor flags (e.g. { "--validate" })
        },
    },

    -- All profiles live under `profiles`. The profile named by
    -- `settings.default_profile` (required) doubles as the *root*
    -- profile: it is activated on setup AND merged underneath every
    -- other named profile, so it's where shared dev-env / MSBuild
    -- settings go. Pick a different named profile at runtime with
    -- `:Msvc profile <name>`.
    profiles = {
        base = {
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
            -- vcvars_ver = "14.39",            -- pin a specific toolset (optional)
            -- winsdk = "10.0.22621.0",         -- pin a Windows SDK version (optional)
            -- vcvars_spectre_libs = "spectre", -- spectre|spectre_load|spectre_load_cf
        },

        -- A named profile holds the full field set (MSBuild parameters
        -- and dev-env parameters together). Anything not declared on
        -- the profile is inherited from the root profile (here `base`).
        debug_x64 = {
            configuration = "Debug",               -- /p:Configuration=
            platform      = "x64",                 -- /p:Platform=
            jobs          = 0,                     -- /m:N
        },
        release_x64 = {
            configuration = "Release",
            platform      = "x64",
            msbuild_args  = { "/nologo", "/v:minimal", "/p:RunCodeAnalysis=false" },
            vcvars_ver    = "14.39",               -- override the inherited toolset
        },
        arm64_release = {
            configuration = "Release",
            platform      = "ARM64",
            arch          = "arm64",
            host_arch     = "x64",
        },
    },
})
```

Activate a profile before building. `:Msvc compile` additionally
sources the dev env from the active profile:

```vim
:Msvc profile debug_x64
:Msvc build
:Msvc compile
```

`settings.default_profile` is **required** and must match a key in
`profiles`. On the first `setup()` call, that profile is activated
automatically — no explicit `:Msvc profile` is needed to get going.
Other named profiles layer on top of it during build resolution.
`setup()` also kicks off an asynchronous `vswhere` lookup to populate
`state.install_path` in the background — `setup()` returns immediately
and the path is filled in by the time you trigger a build.
A configured `install_path` on the root profile (or the active named
profile) short-circuits the lookup.

Merging uses `vim.tbl_extend("force", ...)` — **never recursive**, so array values
(`vs_products`, `msbuild_args`, …) are replaced wholesale.

## Commands

All commands are dispatched through a single `:Msvc <subcommand>` (modeled on
`:Telescope` / `:Lazy`):

- `:Msvc build [target]` — Build the active solution. If a project has
  been pinned via `:Msvc project <name>`, builds that `.vcxproj` instead
  (with `/p:SolutionDir=<sln-dir>\` so `$(SolutionDir)`-relative paths
  still resolve). Optional MSBuild target: `Build` / `Rebuild` / `Clean`.
  Requires an active profile.
- `:Msvc rebuild` — Run MSBuild with `target=Rebuild`.
- `:Msvc clean` — Run MSBuild with `target=Clean`.
- `:Msvc cancel` — Cancel the in-flight MSBuild invocation
  (`taskkill /T /F /PID …`).
- `:Msvc status` — Echo solution / project / install snapshot plus the
  active profile's full field listing.
- `:Msvc log` — Open the build log: live tail while a build is running,
  otherwise the most recent build's captured output.
- `:Msvc profile <name>` — Set (or show) the active named profile from
  `config.profiles`. A profile holds both MSBuild settings
  (`configuration`, `platform`, `target`, `msbuild_args`, `jobs`, ...)
  and dev-env parameters (`arch`, `host_arch`, `vcvars_ver`, `winsdk`,
  `vcvars_spectre_libs`, `vs_*`, `vswhere_path`, `install_path`) on the
  same flat table. Setting a profile logs the full merged field set,
  sorted, one `key = value` per line; showing it without an argument
  does the same for the active profile.
- `:Msvc update <property> <value>` — Override a single property on the
  active profile. All profile properties live on the same flat table:
  `configuration`, `platform`, `target`, `verbosity`, `msbuild_args`,
  `jobs`, `max_cpu_count`, `no_logo`, `extra_args`, `arch`, `host_arch`,
  `vcvars_ver`, `winsdk`, `vcvars_spectre_libs`, `vs_version`,
  `vs_prerelease`, `vs_products`, `vs_requires`, `vswhere_path`.
  `install_path` is a global runtime state value (no profile selection
  required) and is updated directly on the active state. Booleans
  accept `true`/`false`/`1`/`0`/`yes`/`no`. Tables accept comma-separated
  values. Both arguments are tab-completed — property names plus known
  enums for string props, with dynamic enumeration for `vcvars_ver`
  (scans `<install_path>\VC\Tools\MSVC`) and `winsdk` (queries
  `HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots`, with a
  filesystem fallback). `vcvars_spectre_libs` completes to `spectre`,
  `spectre_load`, `spectre_load_cf`. Overrides are **transient** — they
  live on top of the configured baseline and are cleared whenever the
  profile is re-selected via `:Msvc profile`.
- `:Msvc project [name]` — Pin a single project (subset of the loaded
  solution) so subsequent builds target only that `.vcxproj`. Tab
  completion lists the project names parsed from the active `.sln`
  during setup. Pass no argument (or the synthetic `<solution>`) to
  clear the selection and have `:Msvc build` target the full solution
  again.
- `:Msvc discover` — Re-scan cwd for the parent `.sln` and refresh the
  cached project list. Useful when you `:cd` into a different repo
  during the same Neovim session.
- `:checkhealth msvc` — Run the plugin health check (reports OS / Neovim version,
  vswhere & MSBuild discovery, the active solution / project / profile,
  and the `compile_commands.json` extractor configuration).
- `:Msvc compile` — Compile the current buffer's source file (placeholder
  hook; logs a warning until `Msvc:compile_current_file` lands). Requires
  an active profile.
- `:Msvc help` — List every `:Msvc` subcommand.

## compile_commands.json

If the
[`msbuild-extractor-sample`](https://github.com/microsoft/msbuild-extractor-sample)
executable is on `PATH`, nvim-msvc invokes it after every successful
`:Msvc build` to (re)generate a clang-style `compile_commands.json`. The
extractor never compiles anything — it only evaluates the project at
design time and runs `GetClCommandLines`. Modeled on nvim-treesitter's
`tree-sitter` CLI integration: the binary name is **implicit** and not
configurable; when missing, the feature is a no-op and a one-time
warning is logged. Use `:checkhealth msvc` to verify discovery.

```lua
require("msvc").setup({
    settings = {
        compile_commands = {
            outdir   = "C:\\src\\myapp",             -- defaults to the .sln's directory
            builddir = "C:\\src\\myapp\\out\\build", -- optional CMake / out-of-source build dir
        },
    },
})
```

`outdir` (defaults to the active `.sln` directory) is where
`compile_commands.json` is written. Both `outdir` and `builddir` accept
either an absolute path or a relative one; relative paths are resolved
against the active solution's directory, then the active project's
directory, then Neovim's cwd (in that order). When `builddir` is set, every
`*.vcxproj` discovered recursively under it is added as an extra
`--project` input and merged into the same file via the tool's
`--merge --deduplicate` modes — useful for CMake / GN trees that emit
out-of-source `.vcxproj` files alongside the in-tree solution. CMake
VS-generator meta-targets (`ALL_BUILD`, `ZERO_CHECK`, `INSTALL`,
`PACKAGE`, `RUN_TESTS`, `RESTORE`, and the CTest dashboard targets) are
filtered out of the builddir scan so the extractor never receives them.

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
  active profile (merged over the configured root profile); `opts.profile`
  overrides the active profile, `opts.arch` overrides the resolved arch.
- `msvc:status()` — Echo solution/project/install snapshot plus the
  active profile's full field listing.
- `msvc:set_profile(name)` — Switch the active named profile.
- `msvc:set_project(name_or_path)` — Pin a project from the cached
  `solution_projects` (or by `.vcxproj` path); pass `nil` to clear.
- `msvc:auto_discover()` — Re-scan cwd for the parent `.sln` and refresh
  the cached project list; returns the pinned solution path.
- `msvc.log:show_build()` — Open the build log buffer (live tail while
  building, last build's output otherwise).

## Architecture

Module-returns-singleton in `init.lua`; class-style modules with metatables
for stateful pieces (`Msvc`, `MsvcLog`, `MsvcState`, `MsvcBuild`,
`MsvcExtensions`); layered config (`settings` / root profile /
named profile) merged non-recursively with
`vim.tbl_extend("force", …)`; named-event bus
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
  (which ships `vswhere`), or set `vswhere_path` on your default profile in
  `setup` to an explicit path. The fallback search location is
  `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe`.
- **`MSBuild.exe not found`** — Confirm the **Desktop development with C++**
  workload is installed and the resolved install matches `vs_version` /
  `vs_products` / `vs_requires`. Run `:Msvc profile <name>` then
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
