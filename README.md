# nvim-msvc

A **Windows-only** Neovim plugin that wraps `MSBuild.exe` and the Visual
Studio developer environment (`vswhere.exe`, `vcvarsall.bat`) into a
small, async, build/cancel/quickfix workflow modelled after
[harpoon2](https://github.com/ThePrimeagen/harpoon/tree/harpoon2).

## Requirements

- **Windows**, **Neovim ≥ 0.10** (uses `vim.system`).
- **Visual Studio 2017+** with the **Desktop development with C++**
  workload (so `vcvarsall.bat`, `MSBuild.exe`, `cl.exe`, `link.exe` exist).
- `vswhere.exe` (ships with VS 2017 Update 2+).
- *Optional:* [`msbuild-extractor-sample`](https://github.com/microsoft/msbuild-extractor-sample)
  on `PATH` to auto-generate `compile_commands.json` after each build.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "ptquang2000/nvim-msvc",
    cond = function() return vim.fn.has("win32") == 1 end,
    cmd = "Msvc",
    config = function()
        require("msvc").setup({
            settings = {
                default_profile = "release",
                compile_commands = { builddir = "bin/cmake", outdir = "bin" },
            },
            default = {
                msbuild_args = { "/nologo", "/v:minimal" },
                jobs = 6,
            },
            profiles = {
                release = { configuration = "Release", platform = "x64" },
                debug   = { configuration = "Debug",   platform = "x64" },
            },
        })
    end,
}
```

## Configuration

The schema mirrors harpoon2's `default + entries` pattern. Three top-level
keys:

| Key        | Purpose                                                                                |
|------------|----------------------------------------------------------------------------------------|
| `settings` | Plugin-wide knobs: `default_profile`, `log_level`, `build_on_save`, `compile_commands` |
| `default`  | Profile fields merged under **every** named profile                                    |
| `profiles` | Map of profile name → profile fields. `configuration` and `platform` are **required**  |

### Profile fields

Every field is optional except `configuration` and `platform`. They are
shallow-merged in this order: **named profile** → **`default`**.

| Field           | Type      | Notes                                                                |
|-----------------|-----------|----------------------------------------------------------------------|
| `configuration` | string    | `Debug` / `Release` / ... (auto-completed from `.sln` / `.vcxproj`)  |
| `platform`      | string    | `Win32` / `x64` / `ARM64` (auto-completed from `.sln` / `.vcxproj`)  |
| `arch`          | string    | `x86` / `x64` / `arm` / `arm64`. Toolchain arch passed to vcvarsall  |
| `msbuild_args`  | string[]  | Extra MSBuild flags, verbatim (e.g. `{ "/nologo", "/v:minimal" }`)   |
| `jobs`          | integer   | Translated to MSBuild `/m:<n>`                                       |
| `target`        | string    | Default MSBuild `/t:<name>`. Overridden by `:Msvc build [target]`    |
| `vs_version`    | string    | `latest` / `2017` / `2019` / `2022` / `17` / `17.10` / `[a,b]` range |
| `vs_prerelease` | boolean   | Include prerelease installs in vswhere lookup                        |
| `vs_products`   | string[]  | vswhere `-products`                                                  |
| `vs_requires`   | string[]  | vswhere `-requires`                                                  |
| `vswhere_path`  | string    | Explicit `vswhere.exe` path                                          |
| `vcvars_ver`    | string    | Pin MSVC toolset (e.g. `14.16`). Auto-completed from VC\Tools\MSVC   |
| `winsdk`        | string    | Pin Windows SDK (e.g. `10.0.17763.0`). Auto-completed from registry  |

## Subcommands

```
:Msvc                       same as :Msvc help
:Msvc help                  list subcommands
:Msvc status                show solution/project/profile/install
:Msvc build [target]        run MSBuild (target overrides the default)
:Msvc rebuild               MSBuild /t:Rebuild
:Msvc clean                 MSBuild /t:Clean
:Msvc cancel                kill the in-flight build
:Msvc profile [name]        switch active profile (no arg → list)
:Msvc project [path|-]      pin a .vcxproj as the build target ('-' clears)
:Msvc update <field> <val>  override a profile field for this session
:Msvc discover              re-scan cwd for a .sln
:Msvc log                   open the live build-log buffer
```

`:Msvc update <field>` and `:Msvc profile <name>` autocomplete from
`vswhere`, the filesystem, and the active solution/project.

## Health

`:checkhealth msvc` reports environment, configuration, vswhere /
MSBuild discovery, current state, and the `compile_commands.json`
extractor.
