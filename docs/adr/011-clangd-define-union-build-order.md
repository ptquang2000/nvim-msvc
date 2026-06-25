# ADR 011: .clangd define union in build order; compile_commands keep-last dedup

**Status**: Accepted
**Date**: 2026-06-25

## Context

ADR 009 decided `CompileFlags.Add` in the generated `.clangd` reads preprocessor
definitions from the **pinned project only** (`Msvc.project`), using the active
configuration/platform, and omits `Add` entirely when no project is pinned. Its rationale
explicitly rejected a union of all projects' defines:

> a union of all projects' defines is misleading (conflicting macros both true
> simultaneously) ... headers belong to one project context at a time.

In practice this is too narrow. A header opened in isolation frequently depends on defines
contributed by several projects in a solution (shared config headers, feature flags set by an
upstream project and consumed downstream). Restricting `Add` to a single pinned project leaves
those headers under-defined, while the per-`.cpp` entries in `compile_commands.json` already
carry full per-file defines.

Separately, `compile_commands.json` merge (ADR 005) deduplicates by `file`, keeping the
**first** occurrence. With the main solution extracted first, the main solution wins ties —
but the rule was incidental to processing order, not a stated policy, and among sub-solutions
the earliest-scanned arbitrarily won.

## Decision

### `CompileFlags.Add` becomes a build-order union, not pinned-project-only

`Add` is built from the preprocessor definitions of **every project across all extracted
solutions** (the main solution plus sub-solutions found under `cc.builddir`), selected by the
active `Msvc.settings.configuration` / `Msvc.settings.platform`.

This supersedes ADR 009's "pinned project only" decision. The pinned project is no longer the
*source* of `Add`; it becomes the *highest-priority override* (see ordering below). When no
project is pinned, `Add` is still emitted (the union), rather than omitted.

### Override order = build order, later wins

Defines are merged in the following sequence, later entries overriding earlier ones:

1. **Sub-solutions first**, in `cc.builddir` scan order.
2. **Main solution last** (`Msvc.solution`).
3. Within each solution, projects in **`.sln` declaration order** — the order
   `Project(...)` lines appear, as returned by `Discover.parse_solution_projects`.
4. **The pinned project's defines applied last of all**, so a pinned project always wins.

"Build order" here resolves to **`.sln` declaration order**, a deliberate approximation. The
plugin does **not** parse `ProjectDependencies` (solution `GlobalSection`) or
`ProjectReference` (vcxproj) and does **not** compute Visual Studio's true topological build
order. Declaration order is free (already parsed), deterministic, and adequate because the
leaf/application project — the usual authority for conflicting defines — typically appears
late in the `.sln`. The pinned-project-last rule covers the case where it does not.

### Name-keyed dedup — one `-D` per macro

The union is deduplicated by **macro name** (the identifier before `=`), not by full token.
`-DFOO=1` followed by `-DFOO=2` collapses to a single `-DFOO=2`; a bare `-DFOO` and `-DFOO=1`
collide on name `FOO` with the later definition winning. The final `Add` list contains exactly
one entry per macro name.

This is what makes the union safe, and directly answers ADR 009's objection: the `.clangd`
file never contains two conflicting definitions of the same macro. Resolution happens at merge
time and is visible in the file, rather than being left implicit in clang's command-line
last-wins parsing. Because dedup is name-keyed, the order of entries *in the written file* is
not load-bearing for correctness (only the merge sequence that picks the winner is).

### `compile_commands.json` dedup flips to keep-last, `[subs…, main]` order

`merge_temp_files` processes temp files in the order **sub-solutions first, main solution
last**, and keeps the **last** occurrence on a duplicate `file` key (when `cc.deduplicate` is
enabled). Net effects:

- Main solution still wins over sub-solutions on duplicate files (as it did under keep-first +
  main-first), now as a stated policy rather than an accident of order.
- Among sub-solutions, the **later-scanned** sub-solution now wins, where the earliest used to.

This keeps the override principle ("later in build order wins") consistent between the two
generated outputs.

## Consequences

- `discover.parse_vcxproj_defines` is now called per project across all solutions for the
  `.clangd` union, not once for the pinned project. `compile_commands.lua: generate_clangd`
  gains a project-enumeration + merge step.
- Headers that draw defines from multiple projects in a solution now resolve correctly without
  requiring the user to pin a specific project first.
- The union is bounded by name-keyed dedup, so `Add` size is proportional to the number of
  distinct macros, not the number of projects.
- Build order is an approximation (`.sln` declaration order). If a project relies on a
  dependency's define overriding it and the dependency appears *later* in the `.sln`, the
  result will differ from a real MSBuild build. The pinned-project-last rule is the escape
  hatch; true topological ordering is explicitly out of scope.
- ADR 009's "pinned project only" decision for `CompileFlags.Add` is superseded. ADR 009's
  `Remove` flag list, `CompilationDatabase: .`, and co-location decisions are unchanged.
- ADR 005's keep-first / main-first merge behavior for `compile_commands.json` is superseded by
  keep-last / main-last.
