# PRD — Collapse-cursor placement, build-order define merge, and `jobs` clarification

*Generated from conversation context on 2026-06-25*

## Problem Statement

Three unrelated rough edges in the `msvc://` workflow:

1. **Collapsing a list loses the user's place.** When the user collapses an expanded
   settings-field option list (normal mode) or an expanded solution's project list (add
   mode), the cursor keeps its old line number. Because the lines below shift up, the cursor
   lands on an unrelated row — disorienting, especially when collapsing from a child line
   several rows below the title.

2. **`.clangd` IntelliSense is under-defined for multi-project headers.** Per ADR 009,
   `.clangd` `CompileFlags.Add` is sourced from the *pinned project only*. Headers that depend
   on preprocessor defines contributed by several projects in a solution (shared config
   headers, upstream feature flags) get incomplete defines, so clangd misreads them. There is
   also no stated, consistent rule for which definition wins when two projects define the same
   macro, nor for which entry wins when the same file appears in multiple solutions during the
   `compile_commands.json` merge.

3. **`jobs` produces far more processes than its value suggests.** Setting `jobs = 6` spawns
   noticeably more than six processes, which reads as a bug.

## Solution

1. **Anchor the cursor on collapse.** After `=` collapses a list, move the cursor to that
   list's title line (the settings field, or the solution) at the first non-blank column —
   regardless of whether `=` was pressed on the title or on a child line.

2. **Merge defines in build order, later wins.** `.clangd` `CompileFlags.Add` becomes a
   build-order union of defines across all projects in all extracted solutions, deduplicated
   by macro name so the file stays clean and unambiguous, with the pinned project layered last
   (always wins). `compile_commands.json` dedup is made consistent with the same principle.

3. **Document `jobs` semantics; no behavior change.** Clarify in code that `jobs` bounds
   MSBuild *worker nodes* only, not the total process count.

## User Stories

1. As a developer tuning settings, I want the cursor to stay on the field I just collapsed, so
   that I can keep navigating fields without hunting for my place.
2. As a developer collapsing a solution's project list in add mode, I want the cursor to land
   on that solution line, so that repeated expand/collapse cycles stay anchored.
3. As a developer editing a header that pulls defines from several projects, I want `.clangd`
   to carry the union of those defines, so that clangd resolves the header correctly without
   my having to pin a specific project first.
4. As a developer reading a generated `.clangd`, I want exactly one definition per macro, so
   that the file is unambiguous and I can see which value won.
5. As a developer with overlapping files across solutions, I want a predictable, documented
   rule for which `compile_commands.json` entry wins, so that the result is reproducible.
6. As a developer setting `jobs`, I want to understand why the process count exceeds it, so
   that I don't mistake expected MSBuild behavior for a bug.

## Implementation Decisions

### Collapse-cursor placement (ADR 012)

- The `=` collapse handlers in `ui.lua` gain a post-`render()` cursor-reposition step for the
  `SETTINGS_FIELD`, `SETTINGS_OPTION`, `SOLUTION`, and add-mode `PROJECT` branches.
- After re-render, locate the new buffer line whose entity is the collapsed `SETTINGS_FIELD`
  (matched by `field`) or `SOLUTION` (matched by `path`), then set the cursor to that line at
  the first non-blank column.
- Expansion does not move the cursor — only collapse does.

### Build-order define merge (ADR 011; supersedes ADR 009's "pinned project only")

- **`.clangd` `CompileFlags.Add`** is built from the preprocessor defines of every project
  across all extracted solutions (main + sub-solutions under `cc.builddir`), selected by the
  active `configuration`/`platform`. `Add` is emitted even when no project is pinned.
- **Override order (later wins):** sub-solutions first (in `cc.builddir` scan order), main
  solution last; within each solution, projects in **`.sln` declaration order**
  (`Discover.parse_solution_projects`); then the **pinned project's defines applied last of
  all** (highest priority).
- **"Build order" = `.sln` declaration order** — a deliberate approximation. The plugin does
  *not* parse `ProjectDependencies`/`ProjectReference` and does not compute MSBuild's true
  topological order. The pinned-project-last rule is the escape hatch when declaration order
  disagrees with real dependency order. Topological order is out of scope.
- **Name-keyed dedup:** the union is deduplicated by macro name (identifier before `=`). One
  entry per macro name survives; the build-order-last value wins. This is load-bearing — it is
  the specific mitigation for ADR 009's "conflicting macros both true simultaneously"
  objection. Must not be simplified to full-token dedup later.
- **`compile_commands.json` merge** (`merge_temp_files`): process temp files in `[subs…, main]`
  order and keep the **last** occurrence on a duplicate `file` key (when `cc.deduplicate` is
  enabled). Net effect: main solution still wins over subs (as today), now as stated policy;
  among sub-solutions the later-scanned one now wins (was: earliest).
- `discover.parse_vcxproj_defines` is now invoked per project across all solutions for the
  `.clangd` union, not once for the pinned project; `compile_commands.lua: generate_clangd`
  gains the project-enumeration + name-keyed merge step.

### `jobs` clarification (document only, no behavior change)

- `jobs` → MSBuild `/m:N` controls worker-node (project-level) parallelism only. Live process
  count is up to N+1 `MSBuild.exe` (parent scheduler + N workers) plus `cl.exe` children;
  projects with `/MP` (`<MultiProcessorCompilation>`) spawn one compiler per logical core per
  node, which `/m:N` does not bound.
- Add clarifying comments at the `jobs` default (`config.lua`) and the `/m:` mapping
  (`build.lua` `build_argv`). Do **not** pass `/p:CL_MPCount`; cl.exe parallelism stays
  unbounded by `jobs`.

## Testing Decisions

- **Define merge ordering** (`compile_commands_spec.lua`): given fixture solutions with
  projects defining the same macro with different values, assert the final `.clangd` `Add`
  contains exactly one entry per macro name, that the build-order-last value wins, and that a
  pinned project's value overrides all others. Use the `sol-a`/`sol-b`/`sol-c` fixtures
  (per project memory) — `sol-b` Alpha/Beta already exercise per-project config/platform.
- **`compile_commands.json` keep-last dedup** (`compile_commands_spec.lua`): with a file
  present in two solutions, assert the `[subs…, main]` order keeps the main solution's entry,
  and that among two sub-solutions the later-scanned entry wins. Follow the existing
  `merge_temp_files` test pattern.
- **Collapse-cursor placement** (`ui_spec.lua`): simulate `=` on a `SETTINGS_OPTION` child
  line and assert the cursor lands on the parent `SETTINGS_FIELD` line at first non-blank
  column; repeat for an add-mode `PROJECT` line collapsing to its `SOLUTION`. Follow existing
  `ui_spec.lua` cursor/entity-at-line assertions.
- `jobs` documentation needs no test (comment-only).

## Out of Scope

- True topological (`ProjectDependencies`) build order — explicitly deferred; `.sln`
  declaration order is the approximation.
- Bounding `cl.exe` parallelism (`/p:CL_MPCount`) or splitting `jobs` into node-count vs
  compiler-count settings — declined in favor of documentation only.
- Any change to the `Remove` flag list, `CompilationDatabase: .`, or output co-location from
  ADR 009 (unchanged).
- Cursor movement on *expansion* (only collapse repositions).

## Further Notes

- ADRs written this session: `docs/adr/011-clangd-define-union-build-order.md` (supersedes
  ADR 009's "pinned project only"; supersedes ADR 005's keep-first/main-first merge) and
  `docs/adr/012-collapse-cursor-on-title-line.md`.
- Open implementation watch-points: (a) never alphabetically sort the project list returned by
  `parse_solution_projects` — sorting silently changes override semantics; (b) keep
  name-keyed dedup, not full-token; (c) keep pinned-project-last.
