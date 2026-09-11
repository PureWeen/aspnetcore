# Issue readiness evaluation protocol 1.0

Use this protocol for frozen evaluation cohorts. Public smoke cases are
development controls, not held-out evaluation evidence.

## Primary classifications

| Classification | Receipt dispositions |
|---|---|
| `go` | `ready_for_fix_investigation` |
| `stop` | `duplicate_or_already_fixed`, `by_design`, `unsupported_usage`, `invalid_or_incomplete_setup`, `documentation_gap` |
| `human-decision` | `security_process_required`, `product_or_design_decision_required` |
| `inconclusive` | `needs_reporter_evidence_or_repro`, `infrastructure_blocked_or_inconclusive`, `not_reproduced`, `deferred_below_threshold` |

The full disposition remains the operational route. The four classifications are
the evaluation projection.

## Errors, abstention, and coverage

- **False-go:** assessed `go` when sealed ground truth is `stop`,
  `human-decision`, or `inconclusive`.
- **False-stop:** assessed `stop` when sealed ground truth is `go`.
- `human-decision` and `inconclusive` are abstentions for binary go/stop accuracy;
  report them separately rather than counting them as correct by default.
- **Decisive coverage:** `(go + stop) / all cases`.
- **Decisive accuracy:** correct go/stop results divided by decisive results.
- Also report the full four-class confusion counts. High accuracy with low
  decisive coverage is not sufficient evidence of useful readiness decisions.

## Ground truth and allowed evidence

An independent maintainer or evaluation owner seals each expected classification,
accepted disposition(s), rationale, and allowed evidence before assessment begins.
Ground truth must not be authored by the implementation under test.

Allowed assessment evidence is limited to the frozen issue revision, its sealed
upstream triage/comments, declared related issues/releases, the assessed source
SHA, primary documentation, and execution evidence permitted by the readiness
tiers. Completion or implementation quality is out of scope unless independently
checked and sealed as part of ground truth.

## Blinding

- Hide expected outcomes and evaluator rationale from the assessor.
- Do not reveal aggregate failures until the cohort run is complete.
- Do not tune prompts, policy, validator, model selection, or code to held-out
  cases. Any such change ends the cohort and starts a new one.
- Keep Ilona-held-out cases separate from public development smoke cases.

## Frozen cohort manifest

Every cohort records:

1. Cohort and protocol version.
2. Receipt schema version.
3. Skill source commit and hashes for `SKILL.md`, disposition policy, schema, and
   validator, plus their manifest hash.
4. Model/engine identifiers and versions, including explicit unknowns.
5. Tool versions, safety mode, issue revision, and allowed evidence set.
6. Case identifiers and sealed-ground-truth artifact hashes.

Receipts must carry the matching cohort/protocol and source instrumentation.

## Change control

Any implementation, prompt, policy, schema, validator, model, or evidence-policy
change creates a new cohort version. Rerun public controls and all cases assigned
to the new cohort. Never combine results across cohort versions without reporting
them separately.

## Metrics and reporting

Report exact counts: total cases, each four-class outcome, correct classifications,
false-go, false-stop, inconclusive, and human-decision. Report decisive coverage
and decisive accuracy with denominators. Report median and range for wall time,
active execution time, and cost; report unknown counts for each metric.

At `n=10`, report case results and observed counts only. Do not make broad
accuracy, safety, productivity, or production-readiness claims.
