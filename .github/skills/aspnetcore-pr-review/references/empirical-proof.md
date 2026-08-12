# Empirical proof protocol

Read this reference only after a material correctness claim survives adversarial
narrowing or when a structural/contract defect needs calibrated classification.
Also read `proof-calibration.md`.

## Decide whether execution adds information

Do not run empirical work for a compiler error or direct contract contradiction
that is already decisive. Record the structural proof and its limits.

For behavioral claims, empirical adjudication is required before a
blocker-caliber verdict. Multi-model agreement, CI, and current merge status are
corroboration, not runtime proof.

Choose one claim with a concrete trigger, observable failure, authoritative
enough expected result, and faithful smallest boundary. A browser, transport,
process, scheduler, serialization, or interop claim must exercise that producer;
a consumer-only unit test cannot prove what the producer emits.

Before counting behavioral red or green, define the final observable for the
claim, such as a returned value, retained state, generated artifact, rendered UI,
or transmitted payload. Retain a path-execution witness that shows the trigger
reached the changed producer or handoff, and inspect that final observable.
Intermediate metadata alone cannot prove the final observable contract.

## Isolate and freeze

Create an isolated child session or disposable detached worktree at the frozen
head. Record path, SHA, and clean status in `empirical/manifest.md`. Never edit
the parent review worktree. Preserve all artifacts before cleanup; if cleanup is
unsafe, leave the worktree and report it.

Pass the candidate-independent assertion contract, allowed perturbations,
product oracle, impact map, and smallest targeted command to
`aspnetcore-try-fix` in `empirical` mode. Run empirical agents sequentially.

## Proof ladder

Record the highest completed rung per claim:

1. source invariant or contradictory contract;
2. direct consumer behavior;
3. producer classification or dispatch;
4. real integration/runtime interaction;
5. production-candidate regression coverage.

A lower rung cannot prove a higher scenario.

## Frozen-head red before candidate green

Run mapped unchanged tests first. If one distinguishes the defect, use it as the
primary assertion. Then run the approved assertion on untouched frozen head:

- A behavioral failure at the predicted assertion is red.
- A pass rejects or narrows the blocker. Do not manufacture red with a mutation.
- Build, setup, stale-element, timeout-before-trigger, missing asset, unrelated
  assertion, or infrastructure failure is `Blocked`, not behavioral red.

Keep diagnostic assertion and implementation diffs separate. If head is red,
apply the smallest candidate and run the identical assertion for green. Record a
per-execution matrix, its path-execution witness, and the final observable; do
not report only aggregate success. A failure before the changed path executes is
not behavioral red for that change.

In `empirical/result.md`, link the retained frozen and candidate logs that
contain the path-execution and final-observable evidence. In
`empirical/boundary-matrix.md`, record one row for each scoped boundary role:

```markdown
**Frozen path witness:** empirical/head.log
**Candidate path witness:** empirical/green.log
**Frozen final observable:** empirical/head.log
**Candidate final observable:** empirical/green.log
```

| Case ID | Role | Trigger/path | Final observable | Result | Evidence artifact |
|---|---|---|---|---|---|

Use the roles `defect`, `opposite`, and `adjacent` exactly once with distinct case
IDs. `defect` must pass. An opposite or adjacent row may be
`not applicable - <reason>` only when its evidence artifact contains the
source-backed disposition.

At most three implementation iterations may refine one hypothesis. Preserve
blocked output rather than replacing it with confidence-shaped prose.

## Falsify production readiness

The first green supports causality, not production readiness. Preserve:

- finding proof: does frozen head exhibit the predicted defect?
- scenario proof: did the real producer/runtime path exhibit it?
- candidate proof: did the correction survive relevant counterexamples?

For a candidate correction, execute a minimum scoped boundary set:

1. the defect case at the identical assertion;
2. one opposite-side positive control that must retain its existing behavior;
3. the nearest adjacent producer or consumer behavior the mechanism can affect.

Record a source-backed `not applicable` reason when the mechanism has no distinct
opposite-side or adjacent case. Do not invent unrelated cases to fill the table.

Vary only dimensions that could falsify the mechanism. Repeating one deterministic
case proves repeatability, not breadth. Stateful recovery normally requires the
first event after the suppressed interval, the opposite boundary, and any
relevant ownership or provenance transition. Geometry-sensitive work uses a
fixed/no-drift control and one bounded realistic variable perturbation. Do not
build a Cartesian matrix unless an observed divergence requires it.

For shared before/after or batch filtering, cover the producer branches that map
to distinct consumers. For observer-only timeouts, inspect inner task state,
release/cancel it deterministically, and observe exceptions so work cannot leak
into later tests.

For serialization or compatibility work, derive a bounded matrix from the
representation and accessor/constructor paths that can change the external
contract. A targeted green remains provisional until the real producer and
consumer variants plus directly impacted unchanged tests pass. This can promote
a candidate without expanding into unrelated combinations.

A documented build bypass is usable only after an unchanged baseline shows the
blocker and source proves the bypassed target cannot affect the assertion. It
caps proof at `targeted-proven` until standard build or exact CI succeeds.

`production-proven` requires:

- authoritative/corroborated oracle, reproduced mechanism, and exact/proxy
  scenario strong enough for the claim;
- empirical finding and scenario proof;
- required-regression coverage using the same assertion;
- a retained path-execution witness and inspected final observable;
- the scoped defect, opposite-side control, and adjacent-behavior set;
- mapped unchanged tests and real producer boundary passing;
- multiple distinct executed cases and explicit stress-dimension dispositions.

Otherwise classify the candidate as targeted-proven, diagnostic-only, rejected,
or blocked. A proven defect can justify requesting its invariant without
prescribing an unproven implementation.
