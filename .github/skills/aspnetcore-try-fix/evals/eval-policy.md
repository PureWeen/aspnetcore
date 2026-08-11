# Try-fix Vally evaluation policy

This suite follows the shared
[`aspnetcore-pr-review` evaluation anti-overfit policy](../../aspnetcore-pr-review/evals/eval-policy.md).

`aspnetcore-try-fix` is an independently executable Vally 0.13.0 capability
suite. Its canonical cases live in
`eng/skill-evals/aspnetcore-try-fix/regression.vally.yaml`.

Before accepting try-fix changes:

```powershell
pwsh .github/skills/aspnetcore-pr-review/scripts/Validate-Evals.ps1 `
  -Path eng/skill-evals/aspnetcore-try-fix/regression.vally.yaml
pwsh .github/skills/aspnetcore-pr-review/scripts/Test-ReviewerEvalTools.ps1 `
  -Suite TryFix
```

Then strict-lint and run the pinned suite:

```bash
export npm_config_registry=https://packagefeedproxy.microsoft.io/npm/
npx --yes --package @microsoft/vally-cli@0.13.0 vally lint \
  --eval-spec eng/skill-evals/aspnetcore-try-fix/regression.vally.yaml \
  --strict
npx --yes --package @microsoft/vally-cli@0.13.0 vally eval \
  -e eng/skill-evals/aspnetcore-try-fix/regression.vally.yaml \
  --skill-dir /tmp/aspnetcore-review-skills \
  --runs 5 --workers 1 --timeout 1200s \
  --model gpt-5.6-sol --judge-model claude-opus-5 \
  --workspace /tmp/aspnetcore-try-fix/workspaces \
  --output jsonl --output-dir /tmp/aspnetcore-try-fix/artifacts \
  2>/tmp/aspnetcore-try-fix/run.log |
  tee /tmp/aspnetcore-try-fix/results.jsonl
```

The suite independently enforces source snapshots, neutral fixture aliases,
disabled push URLs, objective prompt graders, model/run governance tags,
train/held-out provenance separation, and honest `Blocked`/`Proposed` results.
Snapshots are independent Git repositories, not OS sandboxes. Retained JSONL
and model-authored logs carry command/version/hash provenance but are not
authenticated or tamper-proof.

Every official score uses five completed trials. Preserve raw JSONL, diagnostics,
Vally reports, timing, source commit, skill hashes, and exact models outside the
repository. One-trial runs are diagnostic only. Compare changed skill output
with the frozen old-skill snapshot on representative cases, and keep held-out
provenance disjoint from the train cases used to tune the skill.
