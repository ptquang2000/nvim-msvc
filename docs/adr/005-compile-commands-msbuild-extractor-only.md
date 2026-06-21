# ADR 005: compile_commands generation via msbuild-extractor only, parallel per-solution

**Status**: Accepted  
**Date**: 2026-06-20

## Context

The previous compile_commands generation flow had three moving parts beyond the extractor itself:

1. **`DevEnv.resolve`** — invoked `vcvarsall.bat` via `io.popen` to capture a dev-prompt
   environment (~50 variables) which was then forwarded to the extractor process.
2. **`Discover.discover_vcxproj_toolchain`** — parsed `<WindowsTargetPlatformVersion>` and
   `<PlatformToolset>` from the pinned `.vcxproj` to select the right `vcvarsall.bat` arch
   and toolset version for step 1.
3. **Project collection** — scanned `cc.builddir` for `.vcxproj` files and combined them
   with the pinned project and all solution projects into a flat `--project` list passed to
   the extractor.

Two problems drove this rework:
- `DevEnv.resolve` is a blocking `io.popen` call (runs `cmd.exe /c vcvarsall.bat … && set`)
  executed after every build. It introduced latency and a failure mode (vcvarsall not found)
  that had nothing to do with the extraction itself.
- The project-list approach was inherited from a CMake-centric workflow (`.vcxproj` files
  scattered in a build tree). `msbuild-extractor-sample` can enumerate all projects from a
  `.sln` itself when given `--vs-path`; passing redundant `--project` flags added noise.

Additionally, generation was only triggered after a successful build, which meant a freshly
opened workspace had no `compile_commands.json` until the user ran a build.

## Decision

### Drop `DevEnv.resolve` and `discover_vcxproj_toolchain` from the compile_commands path

`msbuild-extractor-sample` locates MSBuild via MSBuildLocator when `--vs-path` is supplied.
It does not need a pre-captured vcvarsall environment. The `sys_opts.env` injection is
removed; the extractor runs under the plugin process's own environment.

`discover_vcxproj_toolchain` is no longer called from `_run_compile_commands`. It remains in
`discover.lua` for the UI (it still reads toolchain fields for display in the msvc:// buffer).

### Switch from per-project `--project` flags to per-solution runs

Instead of passing every `.vcxproj` as a `--project` argument, each `.sln` file gets its own
extractor invocation with only `--solution`. The extractor enumerates the projects itself.

Sources of solution files:
1. The **main solution** (`Msvc.solution`) — always run first.
2. **Sub-solutions** found by recursively scanning `cc.builddir` (a config field, relative
   to the main solution file) for `**/*.sln`. This covers CMake-generated solution trees
   where each component has its own `.sln` in the build directory.

`cc.builddir` retains its existing semantics as a user-configurable relative path; its
scanned file type changes from `.vcxproj` to `.sln`.

### Parallel job pool with Lua-level JSON merge

All solutions are extracted in parallel. The pool size is `settings.jobs` (the same field
that controls MSBuild's `/m:` flag); when `jobs` is nil the pool is unbounded (all solutions
run concurrently).

Each extractor process writes to a private temp file (`compile_commands.<i>.tmp` beside the
final output). `--merge` is not passed to individual runs. Once all processes complete,
`merge_temp_files` reads every temp file, decodes the JSON arrays via `vim.json.decode`,
concatenates the entries, deduplicates by `file` field (lowercased, when `cc.deduplicate`
is enabled), encodes the result with `vim.json.encode`, and writes the final output. Temp
files are deleted regardless of outcome.

If any extractor process exits non-zero, the merge step is skipped and temp files are
cleaned up. The `on_done` callback receives `false`.

### Explicit generation via msvc:// action page

Generation is triggered from the normal-mode `msvc://` buffer by pressing `g`. The `[g]`
action entry is shown only when `cc.enabled` is not false. Pressing `g` calls
`_run_compile_commands` on the singleton, which resolves the VS install path and spawns the
extractor pool.

The previous auto-trigger on solution selection (`set_solution` calling
`_run_compile_commands`) is removed. Generation now only fires when the user explicitly
requests it, avoiding silent background extraction on every solution switch.

### `--merge-defaults` always passed

Per-file `<PrecompiledHeader>` overrides (`NotUsing`/`Use`/`Create`) cause MSBuild to split
source files into separate `GetClCommandLines` batches. Entries in non-default batches omit
all `ItemDefinitionGroup`-inherited flags (include paths, preprocessor defines, language
standard) unless the extractor backfills them. Passing `--merge-defaults` instructs the
extractor to run `MergeDefaultFlags`, which is additive (only adds flags not already present)
and safe to pass unconditionally. CMake-generated vcxprojs are unaffected (single batch).

### `--deduplicate` strips warning and optimization flags (side effect)

`CompileCommandDeduplicator.CleanSingleEntry` strips `/W*`, `/WX`, `/wd*`, `/we*`,
`/external:W*`, `/O1`, `/O2`, `/Od`, `/Ob*`, `/GL`, `/Gw` from every entry — including
non-duplicated files. This is a side effect of passing `--deduplicate`, not just
deduplication. The stripped flags are acceptable for IntelliSense use (clangd neither
enforces warnings nor requires optimization flags) but make the output unsuitable for build
reproduction. Do not add these flags back as a "fix."

### `--vc-tools-install-dir` derived from selected VS installation

The extractor's auto-detection uses `vswhere -latest` (no version constraint). On machines
with multiple VS versions installed, this disagrees with the version-constrained `--vs-path`
the plugin passes. The plugin owns VS selection (via `resolve_install` / `vs_version`), so it
also owns deriving `VCToolsInstallDir`: scan `{installationPath}\VC\Tools\MSVC\*`, pick the
highest version directory by numeric component comparison, and pass as
`--vc-tools-install-dir`. This guarantees `--vs-path` and `--vc-tools-install-dir` always
reference the same installation.

## Consequences

- The `DevEnv.resolve` / `vcvarsall.bat` round-trip no longer blocks the compile_commands
  path. A failed or missing vcvarsall no longer silently suppresses extraction.
- `--project` flags are gone from the extractor argv. Solutions with many projects no longer
  produce very long command lines.
- The `cc.merge` config field no longer has effect on individual extractor runs (each run
  writes to a fresh temp file). It is kept in the schema for backwards compatibility but is
  effectively ignored; the final output is always written fresh.
- Generation fires only when the user explicitly presses `g` in the `msvc://` buffer.
  vswhere is invoked synchronously at that point via `resolve_install`, which is acceptable —
  vswhere is fast and is already invoked synchronously elsewhere in the build path.
- Users with `cc.builddir` set to a CMake build tree will now have their sub-solutions
  extracted in parallel instead of sequentially, which is faster for large trees.
- `Discover.find_slns` is a new public function on `discover.lua`; `find_vcxprojs` is
  retained (still used by `health.lua` and tests) but is no longer called from the
  compile_commands path.
