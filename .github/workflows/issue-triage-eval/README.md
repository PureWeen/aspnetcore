# Issue triage replay evaluation

This challenge set replays public `dotnet/aspnetcore` issues from frozen,
point-in-time snapshots captured before the 2026-08-26 maintainer triage sweep.
It evaluates only the issue-triage workflow's intended contract:

- exactly one top area label;
- issue type;
- at most one supported subtype;
- removal of `needs-area-label`;
- curated duplicate citations;
- abstention when no change is needed; and
- valid, explicitly targeted safe-output requests.

Severity, affected count, milestones, closure, resolution, servicing,
feature-family labels, and second-area ownership are intentionally excluded.

Public issue content is limited to the data captured in the frozen source snapshots.
This corpus intentionally excludes private issue context, personal workflow state,
and any follow-up maintainer record that was not already public at the snapshot cut.

## Files

- `cases.json` defines accepted answers, evidence URLs, and scoring exclusions.
- `snapshots/*.json` contains frozen public issue inputs and source hashes.
- `capture.mjs` reproduces the snapshots from GitHub issue and timeline APIs. It
  refuses issues with title/body edit events because the original content cannot
  be reconstructed reliably.
- `materialize-trial.mjs` creates a single-case, staged trial workflow with the
  frozen snapshot embedded.
- `score.mjs` scores agent output and optional persisted after-state evidence.
- `aggregate.mjs` scores repeated result exports and reports per-case pass rates
  and decision variance.
- `score.test.mjs` verifies the deterministic scoring contract and safety checks.
- `proof.json` records the retained red/green operational runs that drove exact
  targeting and classifier fixes. Each entry links a GitHub Actions run URL,
  case ID, phase (red or green), score, operational status, and a finding
  summary. All runs used staged safe outputs; persistence was not tested.
- `repeat-proof.json` records the final 25-result aggregate across all 11 cases.
  Summary: 24/25 scored passes, 25/25 output-contract-valid, all 11 cases
  observed. One scored failure is the `68678-external-subtype` case where the
  classifier omits the expected `old-version` subtype. Both proof files are
  read-only evidence and must not be used to infer persistence behavior.

This layer adds the fork-only staged replay execution lane on top of the
frozen public corpus: the committed workflow accepts a bounded `eval_case`
`workflow_dispatch` input, and `materialize-trial.mjs` builds a single-case
trial workflow for `gh aw trial`. Both paths stage every safe output so
replay runs never write to a real issue.

## Run

Refresh the snapshots:

```bash
node .github/workflows/issue-triage-eval/capture.mjs
```

Compile the committed workflow:

```bash
gh aw compile issue-triage-agent
```

For a fork-only trial, materialize one case and run it in staged mode:

```bash
node .github/workflows/issue-triage-eval/materialize-trial.mjs \
  67614-startup-failure \
  .github/workflows/issue-triage-agent-eval-trial.md
gh aw trial .github/workflows/issue-triage-agent-eval-trial.md \
  --host-repo PureWeen/aspnetcore --yes --json
```

The committed workflow also exposes the same bounded cases through
`workflow_dispatch`. Frozen replays are restricted to forks and set all safe
outputs to staged mode. Trial and dispatch runs must not be used to infer
persistence; staged previews prove the requested output contract only.

Score an exported `agent_output.json`:

```bash
node .github/workflows/issue-triage-eval/score.mjs \
  67614-startup-failure \
  /path/to/agent_output.json
```

Run the synthetic scorer tests:

```bash
node --test .github/workflows/issue-triage-eval/score.test.mjs
```

Aggregate repeated result exports:

```bash
node .github/workflows/issue-triage-eval/aggregate.mjs trials \
  issue-triage-repeat- > /tmp/issue-triage-repeat-summary.json
```

The deterministic scorer is intentionally strict about the accepted contract and
exclusions above. It scores only the exported workflow actions for the selected
case and does not assert or prove persistence, workflow execution state, or
future maintainer decisions beyond the public snapshot itself.
