# ADR 013: `jobs` is a total compiler budget split across `/m` and `/p:CL_MPCount`

**Status**: Accepted
**Date**: 2026-06-26

## Context

MSBuild builds were saturating every logical core and making the whole machine's
UI unresponsive. The cause: `jobs` mapped directly to `/m:N`, which bounds only
MSBuild *worker nodes* (project-level parallelism). Projects with
`<MultiProcessorCompilation>` (`/MP`) spawn one `cl.exe` per logical core *per
node* — bounded by neither `/m:N` nor any default the plugin set. Total compilers
scaled with core count (e.g. `6 nodes × 16 cores = 96 cl.exe` on a 16-core box).
`build.lua` previously documented a deliberate decision *not* to pass
`/p:CL_MPCount`, leaving compiler parallelism unbounded.

A single user-facing knob can't independently tune both parallelism axes, and the
naive fix (`/m:jobs` + `CL_MPCount=jobs`) squares the budget to `jobs²` — still an
oversubscription blow-up.

## Decision

Redefine `jobs` as a **total compiler budget** `B` — the maximum number of
`cl.exe` the build may run at once — rather than a direct `/m` node count. Both
MSBuild flags are derived from it with a balanced (square-root) split:

```
L  = vim.uv.available_parallelism()      -- logical cores
B  = jobs (the single knob)
m  = max(1, ceil(sqrt(B)))               -- /m:m            project parallelism
mp = max(1, floor(B / m))                -- /p:CL_MPCount:mp file parallelism
-- total compilers ≈ m * mp ≤ B  (no jobs² blow-up)
```

`build_argv` passes `/m:<m>` and `/p:CL_MPCount:<mp>` whenever `jobs > 0`. The
square-root split is the symmetric hedge: it parallelizes both many-small-project
and few-large-project solutions without the caller knowing the solution's shape,
and guarantees `m × mp ≤ B`.

The **default `jobs` changes from a fixed `6` to `max(1, L - 2)`**, reserving two
logical cores for the UI so the freeze is mitigated out-of-the-box on any machine
with no user tuning. The knob keeps the name `jobs` (no config migration), though
it no longer equals the `/m` node count.

Lowering process **priority** to keep the UI responsive at full parallelism was
considered and deliberately deferred to a later change.

## Consequences

- Reverses the prior inline-comment decision in `build.lua` / `config.lua` (now
  updated): `CL_MPCount` is no longer left unbounded, and `jobs` no longer maps
  one-to-one to `/m`.
- `jobs` no longer equals the worker-node count; reading the argv, `/m` will be
  `ceil(sqrt(jobs))`, not `jobs`. The msvc:// buffer field, `ARCHITECTURE.md`, and
  `README.md` must describe `jobs` as a total compiler budget.
- The default is now machine-relative (`L - 2`) instead of fixed `6`. On a 4-core
  box the build gets `B=2`; on a 32-thread box, `B=30`.
- `CL_MPCount` only affects `/MP`-enabled projects; for non-`/MP` projects only the
  `/m` factor applies (cl runs one file at a time per node regardless).
- `CL_MPCount` never exceeds `L` by construction (`mp ≤ B ≤ L` for the default), so
  the low-core over-subscription hole of the naive `jobs²` model is closed.
