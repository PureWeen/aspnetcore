# Reviewer output contract

Read this reference only during live-head refresh and final synthesis.

## Live-head refresh

Fetch the live PR head and compare it with the frozen SHA. Save the comparison:

- unchanged: proceed;
- unrelated drift: cite why evidence remains applicable;
- relevant source, test, contract, producer, or instruction drift: refresh the
  evidence and impact map, then rerun affected proof and mapped unchanged tests.

Never describe frozen-head evidence as current-head validation.

## Artifact schema

The `**Path:**` field selects the validator contract:

- `bounded` requires shared evidence, candidates A/B, live-head drift,
  `evidence/skipped-phases.md`, repository oracle, and final review. If the
  candidate is `targeted-proven`, also retain the actual frozen-head log,
  candidate-green log, and empirical result. The result records path execution,
  final observable inspection, the defect case, an opposite-side control, and
  adjacent preserved behavior through retained artifact references and
  `empirical/boundary-matrix.md`. Do not create unused full-path boilerplate.
- `full` requires all four candidates, all four cross-examinations, and the
  complete empirical proof tree defined in `evidence-and-orchestration.md`.

The final proof labels must agree with the path. In particular,
`production-proven` requires `full`; bounded `targeted-proven` requires
candidate-independent behavioral red, identical candidate green, empirical
finding/scenario evidence, a required regression assertion, demonstrated path
execution, final observable inspection, and the scoped boundary controls.

For a proven candidate, `empirical/result.md` contains exactly one relative,
nonempty artifact reference for each of `Frozen path witness`,
`Candidate path witness`, `Frozen final observable`, and
`Candidate final observable`. `empirical/boundary-matrix.md` contains distinct
`defect`, `opposite`, and `adjacent` case IDs. Opposite or adjacent may be
not-applicable only with a reason and a nonempty evidence artifact containing
the source-backed disposition.

## Claim synthesis

The GPT orchestrator, not a candidate, assigns:

- **Agree:** independently supported and verified, with no surviving concrete
  counterexample.
- **Dispute:** models disagree or required evidence is incomplete.
- **Discard:** contradicted by source, contract, or observed behavior.
- **Unsupported:** no repository evidence, observed output, or primary source;
  exclude it from required follow-ups and severity.
- **Oracle-blocked:** implementation concern is testable but accepted behavior
  remains unresolved.

Promote a behavioral implementation blocker only when frozen head fails an
independently justified assertion at the required producer boundary and the
causal mechanism and oracle support that severity. If empirical work is blocked,
preserve a disputed concern or required evidence follow-up. If it contradicts
the prediction, discard or narrow the finding.

Choose among equally correct fixes by compatibility, affected producer/consumer
coverage, established repository patterns, and then conceptual/file count.

## Repository knowledge

Write `final/repository-oracle.md` only for durable knowledge that was missing or
hard to find:

- express local mechanics through precise names, named methods or variables, and
  smaller responsibilities; name the concrete structural replacement instead of
  vaguely asking for clearer code;
- reserve concise comments for durable nonlocal reasons that structure cannot
  express, not narration of the call graph or implementation;
- keep public API documentation consumer-observable and exclude internal
  implementation details, including control flow or lifecycle state;
- keep lifecycle/ownership invariants near the state machine and executable
  retention/takeover behavior in paired tests;
- cross-cutting review rules belong in repository instructions.

Do not leak model identities, local paths, private conversation, or review-session
mechanics into repository guidance.

## Final report

Write `final/review.md`:

```markdown
# Multi-Model Review

**Orchestrator:** <GPT model>
**Path:** bounded / full

## Current fix
<summary>

## Independent candidates
| ID | Model | Root cause | Approach | Assessment |
|---|---|---|---|---|

## Adversarial consensus
<for bounded, synthesize the orchestrator comparison of A/B; for full, synthesize
the saved cross-examination round>
### Agree
- <verified claim>
### Dispute
- <unresolved claim>
### Discard
- <rejected claim>

## Test assessment
<frozen-head, candidate, path-execution, final-observable, boundary-control,
mapped-test, and configuration evidence>

## Proof status
**Frozen-head result:** behavioral-fail / structural-defect / pass / blocked / not-applicable
**Finding proof:** empirical / structural / missing
**Scenario proof:** empirical / structural / missing
**Candidate proof:** production-proven / targeted-proven / diagnostic-only / rejected / blocked / none
**Changed path execution:** demonstrated / structural / blocked / missing / not-applicable
**Final observable:** inspected / structural / blocked / missing / not-applicable
**Boundary controls:** passed / partial / blocked / missing / not-applicable
**Product oracle:** documented / author-confirmed / test-encoded / inferred / unknown
**Oracle fidelity:** authoritative / corroborated / hypothesis / unknown
**Mechanism fidelity:** reproduced / structural / inferred / unknown
**Scenario fidelity:** exact / proxy / synthetic / missing
**Regression assertion disposition:** required-regression / optional-regression / rejected
**Diagnostic mutation disposition:** diagnostic-only / rejected / not-applicable

## Final recommendation
**Implementation verdict:** KEEP CURRENT FIX / REVISE / REPLACE
**Behavioral evidence:** empirical / structural / missing
**Merge readiness:** ready / recommendation only / blocked on evidence / blocked on product oracle / blocked on implementation
**Implementation confidence:** high / medium / low
**Reason:** <calibrated evidence>

## Required follow-ups
- <concrete remaining work or None>

## Repository oracle gaps
- <durable follow-up or None>

## Suggested review comments
- <plain-language draft or None>
```

Draft comments as maintainer-facing text: visible failure, causal path, requested
change, and a concrete example when useful. Translate internal terms such as
oracle, ownership, and proof ladder. State what an experiment does not prove.
Never post the draft.
