# PRD — `jobs` as a total compiler budget (UI-responsive builds)

*Generated from conversation context on 2026-06-26. See ADR 013.*

## Problem Statement

When I build a solution from the `msvc://` buffer, MSBuild pins every logical core
and my machine's UI becomes unresponsive — other applications stutter or freeze for
the duration of the build. Lowering the `jobs` setting doesn't help enough, because
`jobs` only bounds MSBuild's project-level parallelism (`/m:N`); each project with
`<MultiProcessorCompilation>` (`/MP`) still spawns one `cl.exe` per logical core,
which nothing caps. On a 16-core machine a `jobs=6` build can fan out to ~96
compiler processes.

## Solution

`jobs` becomes a single **total compiler budget** — the maximum number of `cl.exe`
the build may run at once — and the plugin splits that budget across MSBuild's two
parallelism axes for me. I set one number; the build never exceeds it and leaves
CPU headroom for my UI. By default the budget reserves two logical cores, so builds
stay responsive out-of-the-box without me tuning anything.

## User Stories

1. As a developer building from the `msvc://` buffer, I want my machine's UI to stay
   responsive during a build, so that I can keep using other applications.
2. As a developer, I want a single `jobs` knob to bound the *total* compiler process
   count, so that I don't have to reason about `/m` nodes and `/MP` per-node fan-out
   separately.
3. As a developer who never tunes settings, I want the default to leave CPU headroom
   on whatever machine I'm on, so that builds don't freeze the UI before I touch any
   config.
4. As a developer on a small (4-core) laptop, I want the budget to scale down with my
   machine, so that the build doesn't oversubscribe my cores.
5. As a developer with mixed solutions (some many-small-project, some few-large), I
   want the budget split to parallelize well regardless of solution shape, so that I
   don't have to retune per solution.

## Implementation Decisions

- **Redefine the `jobs` semantic** (name unchanged, no config migration): `jobs` is
  now a total compiler budget `B`, not the `/m` node count. The `msvc://` buffer
  field and its context-store persistence are unchanged structurally.
- **New deep module — `split_budget(B)`**: a pure function returning
  `{ nodes, mpcount }`, behind a simple, stable interface. Logic:
  `nodes = max(1, ceil(sqrt(B)))`, `mpcount = max(1, floor(B / nodes))`. Encapsulates
  the entire split policy so the policy can change without touching `build_argv`.
  Guarantees `nodes * mpcount <= B` (no `jobs²` blow-up). Placed alongside `build.lua`
  (or in `util.lua` if preferred — it's host-independent arithmetic).
- **`build_argv` change**: when `jobs > 0`, call `split_budget(jobs)` and append both
  `/m:<nodes>` and `/p:CL_MPCount:<mpcount>`. When `jobs` is nil/0, emit neither
  (preserves the existing "unbounded" escape hatch). Replaces the current single
  `/m:` line and removes the "we deliberately do NOT pass `/p:CL_MPCount`" comment.
- **Default budget is machine-relative**: `config.DEFAULT_SETTINGS.jobs` changes from
  the literal `6` to `max(1, vim.uv.available_parallelism() - 2)`, reserving two
  logical cores for the UI. `setup()` override still wins.
- **`CL_MPCount` only affects `/MP` projects**: documented, not enforced. For
  non-`/MP` projects only the `/m` factor applies. By construction `mpcount <= B`,
  so the property never over-subscribes relative to core count under the default.
- **Priority lowering is out of scope** for this PRD (see Out of Scope).

## Testing Decisions

- **`split_budget` is the primary unit under test** — pure, deterministic, no host
  dependency. Table-driven cases asserting `(nodes, mpcount)` and the invariant
  `nodes * mpcount <= B`:

  | B | nodes | mpcount | total |
  |---|-------|---------|-------|
  | 2 | 2 | 1 | 2 |
  | 6 | 3 | 2 | 6 |
  | 14 | 4 | 3 | 12 |
  | 30 | 6 | 5 | 30 |
  | 1 | 1 | 1 | 1 |

  Plus edge cases: `B=0` and negative → caller skips (not `split_budget`'s concern,
  but assert the `max(1, …)` clamps hold for `B=1`).
- **`build_argv` argv-composition test** (extend existing `build_spec.lua`): with
  `jobs=6`, assert the argv contains `/m:3` **and** `/p:CL_MPCount:2`; with `jobs`
  nil, assert neither `/m:` nor `/p:CL_MPCount:` appears (the existing "omits /m when
  jobs is nil" test is extended to also assert `CL_MPCount` absence).
- **Prior art**: follow the existing `build_spec.lua` `_build_argv` tests
  (positional `argv[n]` assertions and the `table.concat` + `:find` pattern). Note
  the argv index shift — `jobs=6` previously asserted `argv[6] == "/m:6"`; the target
  arg moves down by one because two parallelism flags are now emitted.
- **`config` default is not unit-tested** — it depends on host core count
  (`available_parallelism`). Left to integration/manual verification, or injected if a
  deterministic test is later desired.

## Out of Scope

- **Process-priority lowering** (BelowNormal/Idle on the MSBuild orchestrator). Agreed
  approach exists (set priority on the orchestrator PID post-spawn; children inherit
  via creation-time inheritance, robust thanks to existing `/nr:false`), but deferred
  to a follow-up change. This PRD covers only the `CL_MPCount` budget split.
- **CPU affinity / core pinning.**
- **Per-axis manual override** (exposing `/m` and `CL_MPCount` as separate buffer
  fields). The single-knob budget model is the deliberate choice.
- **Reproducible-build flag fidelity** — unrelated; the existing `--deduplicate`
  stripping behavior (ADR 005) is untouched.

## Further Notes

- This reverses the documented "cl.exe parallelism stays unbounded" decision in
  `build.lua` / `config.lua`; recorded in **ADR 013**.
- `CL_MPCount` is the same value Visual Studio exposes as *Tools → Options → Projects
  and Solutions → C++ → Maximum Concurrent C++ Compilations*, defaulting to logical
  core count when unset — confirming the property and semantics.
- Open question: with the default `jobs = L - 2`, the worst case still equals the
  budget `B`. If users report the UI still stutters at full budget, the
  priority-lowering follow-up (out of scope here) is the next lever rather than
  shrinking the default further.
- The `split_budget` square-root split is a policy choice that hedges solution shape;
  if profiling later shows project-level parallelism dominates, the split can be
  re-weighted entirely within `split_budget` without changing `build_argv` or the
  `jobs` interface.
