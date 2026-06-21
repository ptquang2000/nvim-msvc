# PRD — WDK Kernel-Mode `km\` Include Path in `.clangd`

*Generated from grilling session — 2026-06-21*

---

## Problem Statement

When a Neovim user opens a Windows minifilter kernel driver project (toolset
`WindowsKernelModeDriver10.0`) and generates `compile_commands.json` + `.clangd` via
the `g` action in the `msvc://` buffer, clangd cannot parse any source file. The root
cause is a missing `km\` include path: `msbuild-extractor-sample`'s `GetClCommandLines`
only surfaces user-mode WDK paths (`ucrt`, `um`, `shared`, `winrt`) because
`$(KernelModeIncludePath)` is not surfaced by `GetProjectDirectories`. Without `km\`,
clangd cannot find `fltkernel.h`, `ntddstor.h`, `ntddvol.h`, or `wdmguid.h` — headers
included by every translation unit via `StdAfx.h`.

---

## Solution

When writing `.clangd`, detect whether the pinned project uses a kernel-mode WDK toolset
and, if so, locate the WDK `km\` include directory and add it as `-I<km_path>` under
`CompileFlags.Add`. Detection uses the `<PlatformToolset>` value already read by
`discover.discover_vcxproj_toolchain`; path resolution uses the Windows Kits registry key
with hardcoded fallbacks.

No changes to `compile_commands.json` generation or the extractor invocation.

---

## User Stories

1. As a kernel driver developer, I want clangd to find WDK kernel headers (`fltkernel.h`,
   `wdm.h`, etc.) after running `g` in the `msvc://` buffer, so that I get working
   IntelliSense in my minifilter project without any manual `.clangd` edits.

2. As a user-mode project developer, I want the `g` action to continue generating `.clangd`
   exactly as before, so that the kernel-mode fix does not affect my project.

3. As a developer on a mixed solution (user-mode + kernel-mode projects), I want the
   kernel-mode path injected only when the pinned project is kernel-mode, so that the
   `.clangd` reflects the actual context I am working in.

---

## Implementation Decisions

### New helper: `find_wdk_km_path(winsdk_version)`

A local function in `compile_commands.lua`, added directly before `generate_clangd`.
Returns the resolved `km\` directory path or `nil`.

Resolution order:
1. Query `HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots\KitsRoot10` via
   `vim.fn.system({"reg", "query", ...})` — synchronous, acceptable post-merge (see ADR 005
   rationale: prohibition is on pre-extractor blocking, not post-merge I/O).
2. Fall back to `C:\Program Files (x86)\Windows Kits\10` then
   `C:\Program Files\Windows Kits\10`.
3. For each candidate root, construct `<root>\Include\<winsdk_version>\km` and return the
   first path where `Util.is_dir` is true.

Uses `Util.join_path` and `Util.is_dir` — existing API, no new dependencies.

The registry value typically ends with a trailing backslash; strip it with
`root:gsub("\\+$", "")` before joining.

### Change to `generate_clangd(opts)`

Replace the current `parse_vcxproj_defines`-only `Add:` block with a unified `add_items`
accumulator:

1. Call `Discover.discover_vcxproj_toolchain(opts.project)` to get `{ winsdk, vcvars_ver }`.
2. If `vcvars_ver:lower():find("kernelmode", 1, true)` — locate `km\` via
   `find_wdk_km_path(toolchain.winsdk)` and prepend `-I<km_path>` to `add_items`.
3. Call `Discover.parse_vcxproj_defines(opts.project, opts.configuration, opts.platform)`
   as before; append each `-D` entry to `add_items`.
4. Write `Add:` block only when `#add_items > 0`.

The `opts.project` guard (`opts.project and opts.project ~= ""`) already gates both calls,
consistent with the existing nil-project behaviour (ADR 009: omit `Add:` when no project
pinned).

### Toolset detection

`"kernelmode"` case-insensitive substring of `<PlatformToolset>` catches
`WindowsKernelModeDriver10.0` and excludes all user-mode WDK toolsets
(`WindowsApplicationForDrivers10.0`, `WindowsUserModeDriver10.0`). No other
kernel-mode toolset variants exist in WDK 10.

### ADR 009 update

`CompileFlags.Add` scope expands from "pinned project defines only" to "toolchain-injected
flags the extractor cannot surface for the pinned project." The section heading and
rationale in ADR 009 are updated accordingly. The YAML example gains a `-I` entry
alongside `-D` entries to make the expanded contract explicit.

### Testability

`find_wdk_km_path` is exposed via `M._internal` (consistent with `merge_temp_files` and
`resolve_outpath`), enabling unit tests to exercise it without running `generate_clangd`.

---

## Testing Decisions

### What makes a good test

- `find_wdk_km_path` with a known-good `winsdk_version` pointing at the real WDK install:
  assert it returns a non-nil path that `Util.is_dir` confirms exists.
- `find_wdk_km_path` with a fake version (e.g. `"99.0.0.0"`): assert it returns `nil`.
- `generate_clangd` with a vcxproj stub containing `WindowsKernelModeDriver10.0` as
  `<PlatformToolset>` and a `winsdk` that maps to a real or test `km\` dir: assert
  `.clangd` contains an `Add:` line matching `-IC:\...\km`.
- `generate_clangd` with a user-mode toolset stub: assert no `-I` line appears in the
  output.

### Modules under test

- `CC._internal.find_wdk_km_path` — direct unit tests
- `CC._internal.generate_clangd` — extend existing `generate_clangd` describe block in
  `lua/msvc/test/compile_commands_spec.lua`

### Prior art

Follow the existing `generate_clangd` test pattern: `vim.fn.tempname()` scratch dir,
write a minimal vcxproj stub with `io.open`, call `CC._internal.generate_clangd(...)`,
read back `.clangd`, assert on content. The `find_wdk_km_path` tests can skip the registry
call and rely on the fallback path logic by temporarily monkeypatching `vim.fn.system` to
return empty string.

---

## Out of Scope

- **Missing WDK preprocessor defines** (`_KERNEL_MODE`, `DBG`, `_WIN64`, etc.) — the
  extractor does not capture these, and they are not defined in WDK props files either
  (`_KERNEL_MODE` is an implicit cl.exe `/kernel` define, unresolvable without MSBuild
  evaluation). Deferred; the `km\` path fix alone unblocks clangd parsing for the known
  use case.
- **Non-`x64` kernel-mode projects** — no evidence of arm64 kernel projects in this repo.
  The `km\` path is architecture-independent; no special handling needed.
- **Parsing WDK `.props` files** for injected defines — ruled out: most interesting defines
  contain unresolvable MSBuild variable references (e.g. `$(NTDDI_VERSION)`).
- **Async `reg query`** — the call is synchronous but runs post-merge (< 10ms). No async
  plumbing needed.
- **Multi-project `.clangd`** — out of scope by ADR 009 design; pinned project is the
  single context.

---

## Further Notes

- The `km\` path is version-specific (`Include\<winsdk_version>\km`). `winsdk_version`
  comes from `<WindowsTargetPlatformVersion>` in the vcxproj, which for libwaacd is
  `10.0.17763.0`. The helper uses this version directly; no fallback to "latest installed"
  is attempted (wrong version would be worse than nil).
- If `discover_vcxproj_toolchain` returns `{}` (vcxproj unreadable), the kernel-mode branch
  is silently skipped — consistent with how `parse_vcxproj_defines` handles the same
  failure.
- The registry `KitsRoot10` value exists on this machine and resolves to
  `C:\Program Files (x86)\Windows Kits\10\`. The fallback list covers the two standard
  install locations.
