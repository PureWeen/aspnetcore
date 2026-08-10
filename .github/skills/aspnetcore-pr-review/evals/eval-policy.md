# Evaluation anti-overfit policy

This policy applies to both `aspnetcore-pr-review` and `aspnetcore-try-fix`. It
protects their evaluation sets from optimizing for a small, recognizable
collection of prompts.

## Retention and scoring

Retain a regression once it is discovered. A lower score weight is not a reason
to delete, weaken, or stop running a regression. Score changes only affect
aggregation; they do not change the required behavioral evidence.

Aggregate scores by taking the mean within each `(tier, score_family)` and then
macro-average families in that tier. Consequently, every eval has normalized
family weight `1 / (number of families in its tier * number of evals in its
tier and family)`; adding near-duplicates cannot increase that family's
influence.

Designate held-out cases before changing the skill, and do not tune prompts,
examples, instructions, or scoring against them. A held-out failure may motivate
a new, separately provenanced train regression, but the original held-out case
remains unchanged.

## Instruction promotion

A regression does not automatically justify another global instruction. Promote
a rule into the always-loaded skill only when:

1. A retained before-change result fails for the reason the rule addresses.
2. The same mechanism transfers to an independently provenanced case outside
   the source PR or subsystem.
3. Held-out no-defect and bounded-stateless canaries do not acquire extra
   blockers or unnecessary lifecycle work.
4. The rule can be stated without source-PR nouns. Otherwise keep it in a
   conditional domain reference.
5. The addition consolidates or replaces narrower guidance when possible,
   rather than growing the skill indefinitely.

Passing only the regression that motivated a rule shows memorization, not
generalization.

## Metadata and controls

Every eval has `eval_metadata`. `mechanism` and `score_family` are lower
kebab-case labels; provenance identifies a PR, historical case, or synthetic
source. `controls.positive` and `controls.negative` are disjoint, nonempty,
zero-based indexes into `expectations`. Positive controls identify evidence that
must be present; negative controls identify an overclaim, unrelated scaffold,
mutation, or side effect the evaluator must reject or avoid. These are
expectation-level grading controls, not substitutes for matched scenario
controls.

Every new defect regression also needs a matched no-defect, alternate-cause, or
scope-control scenario in the same score family before its lesson becomes a
global instruction. The held-out no-defect and bounded-stateless cases are
permanent complexity-inflation canaries.

Discovery prompts must list nonempty `forbidden_prompt_terms`. Those terms must
not occur in the prompt, case-insensitively. Verification prompts may use an
empty list, but every term listed is still forbidden. Keep issue numbers,
implementation names, answer phrases, and other answer-revealing vocabulary out
of discovery prompts. Discovery evals receive frozen evidence through `files`;
removing facts from a prompt without supplying a fixture makes the eval
ungradeable rather than de-leaked.

Held-out evals carry a `frozen_hash`. The validator recomputes it from the full
eval, excluding the hash field itself, so changes to a held-out fixture contract
are explicit. Train and held-out provenance must remain disjoint within a suite.

## Maintenance

Use ablations before accepting a new mechanism or scoring rule: remove the
claimed signal and confirm that the score changes for the intended reason. Prune
only a duplicate or disproven eval, recording the replacement or rationale;
never prune a regression merely because it is inconvenient.

Each expectation must reject a crafted bad result and accept a correct
paraphrase. An expectation that rejects neither is non-discriminating; one that
rejects the paraphrase is a wording matcher. Keep discovery prompts limited to
the evidence a reviewer would receive. Put the mechanism to discover in the
expected result, not in the prompt.

The validator reports family, tier, provenance, and prompt/expectation-overlap
concentration as warnings. These are investigation signals, not arbitrary
acceptance quotas: unusual distributions can be legitimate and must be judged
with provenance and transfer evidence.

Report family-macro and provenance-macro results separately. A source PR can
teach several real mechanisms; one scalar must not let its spread across
families hide poor transfer to other provenance.

Before accepting eval changes, run:

```bash
python3 .github/skills/aspnetcore-pr-review/scripts/validate_evals.py \
  .github/skills/aspnetcore-pr-review/evals/evals.json \
  .github/skills/aspnetcore-try-fix/evals/evals.json
python3 .github/skills/aspnetcore-pr-review/scripts/sync_vally_evals.py --check
python3 .github/skills/aspnetcore-pr-review/scripts/sync_vally_evals.py \
  --stage-skills /tmp/aspnetcore-review-skills
```

The JSON manifests remain the source of truth for provenance, controls, frozen
hashes, and train/held-out governance. `sync_vally_evals.py` projects every case
into the repository-standard Vally schema under `eng/skill-evals/` without
duplicating hand-maintained rubrics.

Use Vally for both repository and local execution. For example, this runs the
documentation-placement case locally with the reviewer skill and Vally's prompt
grader:

```bash
vally eval \
  -e eng/skill-evals/aspnetcore-pr-review/regression.vally.yaml \
  --skill-dir /tmp/aspnetcore-review-skills/aspnetcore-pr-review \
  --tag eval_id=17 \
  --runs 1 \
  --timeout 1200s \
  --model gpt-5.6-sol \
  --judge-model claude-opus-5 \
  --output jsonl
```

The non-GPT orchestrator guardrail is intentionally in
`model-guardrail.vally.yaml` so it can run under `claude-sonnet-5` without
invalidating the GPT-orchestrated cases in the main manifest. These deep-review
specs are standalone Vally capability suites rather than inputs to the generic
`skills-vs-baseline` experiment. They need a sibling skill and repository
identity, so treating a live checkout as the baseline would auto-discover the
skills under test and invalidate the A/B comparison. Direct local runs can
select a case by its `eval_id` tag. Their generated environments use a minimal
git repository and neutral fixture aliases. `--stage-skills` copies only the
runtime files required by the reviewer and its sibling try-fix into a directory
outside the checkout, so repository skill discovery and checked-in answer keys
cannot influence the evaluated model.

A one-trial local run is diagnostic feedback only. Official score aggregation
requires the five trials and executor model pinned in each generated stimulus.
Run the GPT suites and the Claude guardrail separately when using direct Vally:

```bash
vally eval \
  -e eng/skill-evals/aspnetcore-pr-review/regression.vally.yaml \
  --skill-dir /tmp/aspnetcore-review-skills/aspnetcore-pr-review \
  --runs 5 --timeout 1200s \
  --model gpt-5.6-sol --judge-model claude-opus-5 \
  --output jsonl --output-dir /tmp/pr-review-main
vally eval \
  -e eng/skill-evals/aspnetcore-pr-review/model-guardrail.vally.yaml \
  --skill-dir /tmp/aspnetcore-review-skills/aspnetcore-pr-review \
  --runs 5 --timeout 1200s \
  --model claude-sonnet-5 --judge-model claude-opus-5 \
  --output jsonl --output-dir /tmp/pr-review-guardrail
vally eval \
  -e eng/skill-evals/aspnetcore-try-fix/regression.vally.yaml \
  --skill-dir /tmp/aspnetcore-review-skills/aspnetcore-try-fix \
  --runs 5 --timeout 1200s \
  --model gpt-5.6-sol --judge-model claude-opus-5 \
  --output jsonl --output-dir /tmp/try-fix
```

Vally supplies the score-producing prompt grader, repeated trials, and
pass@k/pass^k reporting. Run `scripts/aggregate_eval_scores.py` with both JSON
governance manifests and one or more
`--vally-results <skill-name>=<results.jsonl>` arguments to additionally report
raw, family-macro, provenance-macro, and train-to-held-out transfer results.
The reviewer aggregation needs both its GPT and Claude result files:

```bash
python3 .github/skills/aspnetcore-pr-review/scripts/aggregate_eval_scores.py \
  .github/skills/aspnetcore-pr-review/evals/evals.json \
  .github/skills/aspnetcore-try-fix/evals/evals.json \
  --vally-results aspnetcore-pr-review=/tmp/pr-review-main/<timestamp>/results.jsonl \
  --vally-results aspnetcore-pr-review=/tmp/pr-review-guardrail/<timestamp>/results.jsonl \
  --vally-results aspnetcore-try-fix=/tmp/try-fix/<timestamp>/results.jsonl
```

The legacy `--scores <path>` input remains available for importing results from
another evaluator.

### Grader infrastructure failures

A malformed or timed-out judge response is infrastructure failure, not a zero
quality score. Preserve the original JSONL, regrade its failed trajectory, and
preserve the repaired JSONL separately:

```bash
jq -c \
  'select(.type != "run-summary" and any(.gradeResult.details[]?; .metadata.error? != null))' \
  <original-results.jsonl> |
  vally grade \
    -e <eval.vally.yaml> \
    --judge-model claude-opus-5 \
    --output jsonl >regraded.jsonl
```

Pass the original result before the regraded result to
`aggregate_eval_scores.py`. A later successful grade may supersede only an
earlier grader-error record with the same trajectory ID. Duplicate successful
records, unresolved grader errors, agent failures, and missing trials remain
fatal. Retain both files so the repair is auditable.
