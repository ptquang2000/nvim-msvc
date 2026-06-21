# ADR 010: WDK kernel-mode preprocessor defines in generated `.clangd`

**Status**: Accepted  
**Date**: 2026-06-21

## Context

WDK kernel-mode projects use `PlatformToolset = WindowsKernelModeDriver10.0`. MSBuild
evaluates a chain of WDK `.props` files at build time that inject preprocessor defines
which never appear in the `.vcxproj` itself:

- **Architecture defines** (`_WIN64;_AMD64_;AMD64` for x64) — from `WindowsDriver.x64.props`.
- **OS version defines** (`_WIN32_WINNT`, `WINVER`) — from `WindowsDriver.OS.Props` +
  `WindowsDriver.Shared.Props`, derived from `WindowsTargetPlatformVersion`.

`msbuild-extractor-sample` captures `/D` flags from the final CL invocation. When it
does not run a full MSBuild evaluation these props-injected defines are silently absent
from `compile_commands.json`. The result is fatal clangd errors originating from
`shared/ntdef.h`: `_AMD64_` is required at line 169 and `_WIN32_WINNT` at line 1544,
before `sdkddkver.h` auto-sets it later in the file.

## Decision

### Detection

Kernel-mode projects are identified by `PlatformToolset` containing the substring
`"kernelmode"` (case-insensitive). This is read via `discover_vcxproj_toolchain` and
stored in the `vcvars_ver` field. The check is the same guard already used in
`generate_clangd` to inject the `km\` include path.

Alternatives rejected:
- **`km\` include presence in compile_commands**: circular — absent for the same reason
  we are fixing.
- **Filesystem check for `km\` subdirectory under the WDK SDK path**: adds I/O;
  PlatformToolset is already parsed and is the canonical signal.

### Architecture defines — full WDK set, hard-coded table

For each `Platform` the plugin injects the same set that `WindowsDriver.{platform}.props`
injects:

```
x64   → -D_WIN64  -D_AMD64_  -DAMD64
ARM64 → -D_WIN64  -D_ARM64_  -DARM64
ARM   → -D_ARM_
Win32 → -D_X86_
```

The table is hard-coded in Lua rather than parsed from the props files at runtime. The
mapping mirrors CPU ISA and is stable across WDK versions. Clang's `--target` already
defines `_WIN64` for x64 targets, making that entry redundant, but injecting the full
set matches the WDK contract exactly and redefining a macro to the same implicit value
is benign.

### OS version defines — derived from `WindowsTargetPlatformVersion`

`toolchain.winsdk` holds `WindowsTargetPlatformVersion` (e.g. `10.0.17763.0`). The
major Windows version maps to the hex constant:

```
10  → 0x0A00   (Windows 10 / Server 2016+)
6.3 → 0x0603   (Windows 8.1 / Server 2012 R2)
6.2 → 0x0602   (Windows 8 / Server 2012)
6.1 → 0x0601   (Windows 7 / Server 2008 R2)
```

`_WIN32_WINNT` and `WINVER` are both set to this value. `WINNT=1` (also present in
`WindowsDriver.Shared.Props`) is not injected — it is a legacy NT guard with no
practical effect on clangd parsing of modern WDK headers.

### `NTDDI_VERSION` — deferred

`NTDDI_VERSION` requires the `_NT_TARGET_VERSION` sub-version (TH1, TH2, RS1–RS5, …),
which is computed in the WDK `.targets` chain and not exposed in the `.vcxproj`.
Injecting an incorrect `NTDDI_VERSION` would silently hide RS2+ APIs in LSP even when
the real build targets RS5. Deferred until a reliable derivation path exists (e.g.
mapping the SDK build number from `WindowsTargetPlatformVersion`).

## Consequences

- `generate_clangd` gains two local helpers: `wdk_arch_defines(platform)` and
  `wdk_win32_winnt(winsdk)`.
- The `km\` include injection and the define injection share the same kernel-mode guard
  and are added to `add_items` together in sequence.
- Non-WDK MSVC projects are unaffected — the guard fires only when `vcvars_ver`
  contains `"kernelmode"`.
