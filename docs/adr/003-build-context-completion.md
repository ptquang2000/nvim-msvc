# ADR 003: Build command takes context label, not MSBuild target

**Status**: Superseded by ADR 004  
**Date**: 2026-06-08

## Context

`:Msvc build [target]` previously accepted an optional MSBuild `/t:` argument (e.g. `Rebuild`, `MyCustomTarget`). There was no tab-completion for this argument. The common MSBuild targets were already covered by dedicated subcommands (`:Msvc rebuild`, `:Msvc clean`), making the raw target argument rarely used.

The `_context_store` accumulates `(solution, project)` → `{profile_name, overrides}` entries as the user switches between solutions and projects. There was no way to quickly jump to a previously-used context and build it in one step.

## Decision

`:Msvc build [context-label]` now accepts an optional context label instead of an MSBuild `/t:` target. If a label is supplied, the plugin switches to the corresponding `(solution, project)` context (via `set_solution()` + `set_project()`) and then builds. If no label is supplied, the current context is built as before.

Tab-completion lists all `(solution, project)` pairs present in `_context_store` (plus the current context if not already stored), with `_last_build_key` — the key of the most recent `build()` dispatch — sorted first.

`_last_build_key` is set on the `Msvc` singleton immediately before `Build.spawn()` is called and is `nil` until the first build of the session.

The raw MSBuild `/t:` override is removed from `:Msvc build`. Custom targets can be set persistently via `:Msvc update target <value>`.

## Consequences

- `:Msvc build <tab>` is a combined context-switcher + build trigger. One keystroke to resume the last build context.
- The MSBuild `/t:` positional argument is a breaking change for anyone who called `:Msvc build Rebuild` directly (they should use `:Msvc rebuild` instead).
- `_last_build_key` is session-only and in-memory, consistent with `_context_store`.
