# Reviewer output contract

Read this reference only during live-head refresh and final synthesis.

## Live-head refresh

Fetch the live PR head and compare it with the frozen SHA. Save the comparison:

- unchanged: proceed;
- unrelated drift: cite why evidence remains applicable;
- relevant source, test, contract, producer, or instruction drift: refresh the
  evidence and impact map, then rerun affected proof and mapped unchanged tests.

Never describe frozen-head evidence as current-head validation.

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

- public behavior belongs in API documentation;
- lifecycle/ownership invariants belong near the state machine;
- retention/takeover behavior belongs in paired tests;
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
### Agree
- <verified claim>
### Dispute
- <unresolved claim>
### Discard
- <rejected claim>

## Test assessment
<frozen-head, candidate, mapped-test, and configuration evidence>

## Proof status
**Frozen-head result:** behavioral-fail / structural-defect / pass / blocked / not-applicable
**Finding proof:** empirical / structural / missing
**Scenario proof:** empirical / structural / missing
**Candidate proof:** production-proven / targeted-proven / diagnostic-only / rejected / blocked / none
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
