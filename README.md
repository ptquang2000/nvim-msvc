# nvim-msvc

A **Windows-only** Neovim plugin that wraps `MSBuild.exe` and the Visual Studio developer
environment (`vswhere.exe`, `vcvarsall.bat`) into a buffer-driven build workflow modelled
after [harpoon2](https://github.com/ThePrimeagen/harpoon/tree/harpoon2).

All build configuration and dispatch happen in a single interactive `msvc://` buffer.
There are no subcommands to memorise beyond opening it.

## Requirements

- **Windows**, **Neovim ≥ 0.10** (uses `vim.system`).
- **Visual Studio 2017+** with the **Desktop development with C++** workload
  (`vcvarsall.bat`, `MSBuild.exe`, `cl.exe`, `link.exe`).
- `vswhere.exe` (ships with VS 2017 Update 2+).
- *Optional:* [`msbuild-extractor-sample`](https://github.com/microsoft/msbuild-extractor-sample)
  on `PATH` — auto-generates `compile_commands.json` and `.clangd` after every successful build.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "ptquang2000/nvim-msvc",
    cond = function() return vim.fn.has("win32") == 1 end,
    config = function()
        require("msvc").setup({
            settings = {
                compile_commands = { builddir = "bin/cmake" },
            },
            default_settings = {
                arch = "x64",
                jobs = 4,
            },
        })
    end,
}
```

## Configuration

Two top-level keys:

| Key               | Purpose                                             |
|-------------------|-----------------------------------------------------|
| `settings`        | Plugin-wide knobs (vswhere, compile_commands, etc.) |
| `default_settings`| Starting values for each new (solution, project) context |

### `settings`

| Field              | Type      | Default    | Notes                                         |
|--------------------|-----------|------------|-----------------------------------------------|
| `vswhere_path`     | string    | nil        | Explicit path to `vswhere.exe`                |
| `vs_requires`      | string[]  | `{}`       | Extra `-requires` components for vswhere      |
| `log_level`        | string    | `"info"`   | `"trace"` / `"debug"` / `"info"` / `"warn"` / `"error"` |
| `compile_commands` | table     | see below  | Settings for `compile_commands.json` generation |

**`compile_commands` sub-fields:**

| Field          | Type     | Default       | Notes                                         |
|----------------|----------|---------------|-----------------------------------------------|
| `enabled`      | boolean  | `true`        | Enable/disable generation                     |
| `builddir`     | string   | `"bin/cmake"` | `--build-dir` passed to the extractor         |
| `deduplicate`  | boolean  | `true`        | Remove duplicate entries across solutions     |
| `extra_args`   | string[] | `{}`          | Additional extractor arguments                |

`compile_commands.json` is written next to the active `.sln`. A `.clangd` config is
written to the same directory with MSVC-incompatible flags stripped and project
preprocessor defines injected (when a project is pinned).

### `default_settings`

Starting values for every new `(solution, project)` context. All fields are
overridable per-context from the `msvc://` buffer.

| Field           | Type    | Default    | Notes                                              |
|-----------------|---------|------------|----------------------------------------------------|
| `configuration` | string  | nil        | e.g. `"Debug"` / `"Release"`                       |
| `platform`      | string  | nil        | e.g. `"x64"` / `"Win32"` / `"ARM64"`              |
| `arch`          | string  | `"x64"`    | Toolchain arch for `vcvarsall.bat`                 |
| `vs_version`    | string  | `"latest"` | `"latest"` / `"2019"` / `"2022"` / version range  |
| `jobs`          | integer | `6`        | Parallel MSBuild jobs (`/m:<n>`)                   |

## Subcommands

| Command            | Description                                            |
|--------------------|--------------------------------------------------------|
| `:Msvc`            | Open the `msvc://` buffer                              |
| `:Msvc add [path]` | Register a `.sln` file; no path opens discovery mode   |
| `:Msvc cancel`     | Cancel the in-flight build                             |
| `:Msvc log`        | Open the live build-log buffer                         |

`:Msvc` dispatch: 0 registered solutions → discovery/add mode; 1 solution → normal mode;
2+ solutions → add mode to choose the active one.

## msvc:// buffer

### Normal mode

The buffer shows the active solution, current build target, all editable settings,
and the project list for the active solution.

```
Solution: /path/to/Active.sln
Target: build
Help: h?

  configuration  Debug
  platform       x64
  arch           x64
  vs_version     latest
  jobs           4

────────────────────────────────

  ProjectA
* ProjectB
  ProjectC
```

**Keybindings:**

| Key  | Action                                                          |
|------|-----------------------------------------------------------------|
| `b`  | Set target to `build`                                           |
| `c`  | Set target to `clean`                                           |
| `r`  | Set target to `rebuild`                                         |
| `f`  | Set target to `compile_file` (requires a pinned project)        |
| `g`  | Set target to `generate` (compile_commands + .clangd only, no build) |
| `=`  | Expand field options; collapse if cursor is on an option line   |
| `-`  | On a project line: pin / unpin. On an option: apply value       |
| `:w` | Fire the current target against `(solution, project)`           |
| `l`  | Open log buffer                                                 |
| `x`  | Cancel in-flight build                                          |
| `h?` | Open `msvc-help://` keybinding reference                        |
| `q`  | Close buffer                                                    |

`b` / `c` / `r` / `f` work from any cursor position. When a project is selected (`*`),
`:w` builds that project alone; otherwise it builds the full solution.

Pressing `=` on a settings field expands the known values inline. Options for
`configuration` and `platform` are parsed from the active `.sln`; `arch` uses a
fixed list; `vs_version` queries vswhere. Press `-` on an option to apply it.

### Add mode

Opened automatically when no solutions are registered, or explicitly via `:Msvc add`
with no argument.

```
Solution: /path/to/LastStaged.sln
Help: h?

────────────────────────────────

  Staged
    * MySolution.sln
      OtherSolution.sln

  Unstaged
      Found.sln
```

**Keybindings:**

| Key    | Line type    | Action                                               |
|--------|--------------|------------------------------------------------------|
| `<CR>` | Unstaged     | Stage + activate → switch to normal mode             |
| `<CR>` | Staged       | Activate → switch to normal mode                     |
| `-`    | Unstaged     | Stage (stay in add mode)                             |
| `-`    | Staged       | Unstage; discards that solution's settings history   |
| `:w`   | —            | Activate last staged → switch to normal mode         |
| `=`    | Staged       | Toggle project list visibility                       |
| `l`    | —            | Open log buffer                                      |
| `x`    | —            | Cancel in-flight build                               |
| `h?`   | —            | Open keybinding reference                            |
| `q`    | —            | Close buffer                                         |

The `Solution:` header always shows what `:w` will activate. `<CR>` and `:w`
transition in-place to normal mode without closing the buffer.

## Per-context settings

Settings are stored per `(solution, project)` context key. Switching solution or
project saves the current settings and restores the saved settings for the new
context, or falls back to `default_settings` for a new context. Unstaging a
solution discards its settings history.

## Highlight groups

All groups are defined with `default = true` so user overrides win.

| Group                | Links to    | Applied to                         |
|----------------------|-------------|------------------------------------|
| `MsvcHeaderLabel`    | `Title`     | `Solution:` / `Target:` / `Help:`  |
| `MsvcHeaderValue`    | `Directory` | Path, target value, `h?`           |
| `MsvcField`          | `Identifier`| Settings field names               |
| `MsvcValue`          | `Constant`  | Settings field values              |
| `MsvcOption`         | `Comment`   | Non-selected expanded options      |
| `MsvcOptionSelected` | `Statement` | Currently selected expanded option |
| `MsvcProject`        | `Normal`    | Project names                      |
| `MsvcProjectSelected`| `Special`   | `*` marker on the selected project |
| `MsvcSeparator`      | `Comment`   | Separator line                     |
| `MsvcStagedHeader`   | `Title`     | `Staged` subheader in add mode     |
| `MsvcUnstagedHeader` | `Comment`   | `Unstaged` subheader in add mode   |

## Health

`:checkhealth msvc` validates the environment: vswhere and MSBuild discovery,
active configuration, and the `compile_commands.json` extractor.
