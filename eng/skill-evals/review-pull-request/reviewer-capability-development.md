# Reviewer concurrency capability development suite

This specialized suite measures source-grounded discovery and restraint in one
Copilot context over curated, genuine ASP.NET Core pull-request projections.
It does not replay the hosted review service, prove coordinator/per-guide-worker
fidelity, estimate population accuracy, compare model families, or demonstrate
a reviewer repair.

The completed original #70106 supplied-candidate pilot remains separate and
immutable: three baseline attempts, zero treatment attempts, and no guide
promotion. That pilot calibrated a supplied candidate. The new suite asks for
an ordinary review without staging that candidate, its location, its expected
answer, later maintainer feedback, or grader material.

## Primary pilot cases

| Case | Frozen source and cutoff | Source-backed outcome |
|---|---|---|
| #70106 restraint | Head `2edf3761692afe15475075eb2fc0088566162045`; merge base `10bc886bfa321718276619d1077cc14eaf48456f`; feedback before `2026-10-31T12:50:58Z` | `NO_FINDINGS` is valid. Head prevents an event during the awaited token request from repopulating the shared cache, although that request may use its local header. The residual post-check/no-await race requires genuinely concurrent provider notification, whose supported product contract is not established, and the materially equivalent stale-cache effect predates the pull request. A P2 lock demand, blanket parallel-impossibility claim, or invented provider prohibition fails. |
| #66753 async positive | Head `d98775db95835cdddf5f1dc2dc94fccee7c2c83d`; merge base `fe653b1785eee180496bc313c1e17119c088e150`; feedback before `2026-05-20T15:09:01Z` | The added spacer callbacks at lines 606 and 626 ignore real user-scroll callbacks while `ScrollToIndexAsync` awaits provider/render work, allowing the older operation to resume and align to its stale target despite the contemporaneous PR contract that user scrolling wins. The viewport consequence is source-inferred in this eval; target browser code is not executed. The merge base lacks this feature. Later commit `5191c02677f40c1f116ab4b32c6a19523b668605` cancels the in-flight scroll/provider work and adds browser coverage for this exact overlap. |
| #57972 supported-parallel positive | Head `0a8373f036c151ae2773f4e5a1cb4aeccade6bce`; merge base `542f2b9877da67e90cca6ce1b65aa9557fbb2aa8`; feedback before `2024-09-19T20:14:43Z` | The advertised concurrent-document fix converts several caches but leaves `_operationTransformerContextCache` as `Dictionary` on a keyed-singleton service whose concurrent HTTP request path calls `TryAdd`. The field predates the pull request, but converting every shared mutable cache is a binding obligation for this concurrency fix. Follow-up `cb01ee07234372356dbd64cffd575e0603c91a38` converts it and changes the test to `Parallel.ForAsync(0, 150, ...)`; the author reported that the stronger test exposed the omission. |

#66753 uses the actual target merge base computed from the reviewed commit.
The later live PR base SHA is not substituted as historical provenance. All
#66753-derived evidence remains one development lineage, not an independent
vote. The same rule applies to #70106 and its original calibration.

The earlier #69659, #67589, and #68895 fixtures remain optional secondary
development controls for test discrimination, feedback deduplication, and
configuration restraint. They are not in the first paid pilot and do not
establish concurrency breadth.

## Blinding and projections

Public case and stimulus identifiers are neutral PR numbers. Each bundle
contains the complete frozen diff and changed-file list, ordinary Git blobs for
every changed file plus named producer/consumer/contract paths, and feedback
strictly before the label-source comment. Expected outcomes, later fixes,
later maintainer feedback or opinions, and the rubric remain outside subject
staging. Legitimate feedback that predates each cutoff is intentionally staged.

The PR descriptions are not current mutable bodies. Each is the latest exact
GitHub `userContentEdits.diff` body version before its cutoff. When a PR has no
body edit history, the current body is retained only with the recorded empty
history and pre-cutoff creation identity. Historical labels are not available
from that API, so labels and post-cutoff decision metadata are omitted rather
than projected from present state.

`grading_environment.files` adds labels and the semantic rubric only to
Vally's disposable grader workspace. This is a configured staging boundary,
not proof of host-level secrecy on a shared machine. The accepted claim is
limited to no configured subject exposure and no observed trajectory access.
The grade result records configured evidence inputs and source-consistent
rationale, but does not retain exact grader file-read events.

The focused #70106 projection includes runtime-aware dispatcher and host-builder
source, but not the broader #66729 and #54365 support history used in the
separate supplied-candidate calibration. Absence of that history cannot prove
either supported arbitrary off-thread notifications or a binding provider
prohibition. This suite is a curated natural review, not a full historical
support replay.

## Execution and scoring

`reviewer-capability.vally.yaml` uses the pinned Vally 0.19.0 and Copilot
1.0.80/SDK 1.0.15 path. Every trusted caller prompt explicitly configures the
review skill's documented offline exception: apply the same routed guide texts
and acceptance gates in one context, spawn no workers, and report
`PATH: single-reviewer`. The suite therefore measures one-pass review behavior,
not independent guide-worker synthesis.

The prompt grader uses Vally's supported `gradeTrial` path with
`evidence: [trajectory, repo]`. Native skill activation, complete assigned
guide reads, exact model/case/run provenance, prohibited tools, answer access,
and the single-reviewer receipt are independent integrity gates and receive no
semantic credit. Automated acceptance is necessary but not sufficient; every
subject output still requires source adjudication, especially a plausible
finding outside the label key.

The canonical `prepare-review.cs --check` path is live-target and preparation
version bound, so it cannot attest these historical suite-local projections.
The suite does not manufacture current heads or synthetic Git identities.
`check_reviewer_capability.ps1` instead validates every projected source as an
ordinary Git blob, complete diffs and changed-file metadata, exact historical
body and feedback cutoffs, common/case overlay equality, artifact hashes,
answer separation, and frozen reviewer criteria.

Six derivative trajectories exercise the same semantic scoring path:

1. revision-qualified #70106 restraint;
2. unsupported #70106 P2 lock demand;
3. invented provider-prohibition justification;
4. correct #66753 async-overlap finding;
5. correct #57972 supported-parallel finding;
6. structurally complete blanket silence on the #66753 positive.

Controls retain the same structured review format and `PATH: single-reviewer`
receipt. They are judge-development controls, not subject executions,
historical replays, or independent votes. Vally `grade` can exit zero for a
valid negative score, so control validation must assert each named semantic
score against its expected relation.

## Observed bounded pilot

The first #70106 command failed before model execution because Vally resolves
`environment.skills` relative to the eval specification. That error is
retained as reviewer CLI attempt 1. After correcting only the relative path,
the authorized compatibility recovery ran once as reviewer CLI attempt 2,
run `3cf0bd32-d93e-41ca-8650-547caafe9379`.

That unhinted GPT-5.6 review reproduced the original failure mode. It emitted
an actionable P2 lock-and-generation demand for the post-check/cache-store
window and assumed multithreaded WebAssembly reachability without establishing
a supported producer or a binding requirement to make the pre-existing
mechanism atomic in this pull request. The output did not explicitly say that
the field or mechanism was newly introduced. The associated Gemini grade was
binary 0 for the intended source-backed reason.

The first associated-grade command and the first three control-grade commands
failed before judge execution because `--stimulus` is invalid for saved
`EvalOutcome` input. Corrected grade commands then produced:

- revision-qualified #70106 restraint: 1;
- unsupported P2 lock demand: 0;
- invented provider prohibition: 1, unexpectedly.

The third control was ambiguous because the false guarantee appeared under
`DISCARDED`; the judge interpreted the text as a proposition the reviewer
rejected rather than a justification it relied upon. Its retained run input
and result are the measurement record. The development trajectory now states
the reliance explicitly, but that revision is unmeasured because the
judge-only CLI allowance was exhausted and no selective retry is permitted.
This is an honest control-fixture failure, so #66753 and #57972 were not run.

Ledger:

- reviewer CLI attempts `2/6`, actual reviewer model calls `1`;
- associated-grade CLI attempts `2/6`, actual associated judge calls `1`;
- judge-only control CLI attempts `6/6`, actual control judge calls `3`;
- original supplied-candidate pilot remains baseline `3/3`, treatment `0/3`.

The retained subject run also reported that `projection-map.json` was not
staged beside the bundle manifest. The measured run is preserved unchanged;
the current spec stages that referenced metadata for future use.

These results establish a development recurrence in the configured
one-context path and a useful grader red result. They do not establish hosted
coordinator/worker reliability, population error rates, or a demonstrated
repair. Evidence preloading and coordinator fact gates remain hypotheses for a
later real-pipeline comparison, not changes evaluated here.

This is an exploratory, non-gating result: one observed unhinted repeat, not a
recurrence rate. The two positive cases remain designed but unrun, and no
reviewer or guidance fix is claimed. The saved grade used the #70106 fixture
bundle as repository evidence rather than the original complete subject
overlay workspace; exact judge file-read events were not retained. Its binary
0 is supported by the label and manual source adjudication, not independent
ground truth supplied by the judge.

## Revision rules

- Revise a source label only when new primary evidence contradicts it; retain
  the old revision and reason.
- Revise the grader only when same-path controls expose substantive semantic
  discrimination failure, never to require hidden wording or formatting.
- A harness, judge, loading, or role-fidelity failure is not reviewer evidence.
- Report case outcomes and limitations directly; these related development
  cases do not support a population rate.
