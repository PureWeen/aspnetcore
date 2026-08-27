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

## Files

- `cases.json` defines accepted answers, evidence URLs, and scoring exclusions.
- `snapshots/*.json` contains frozen public issue inputs and source hashes.
- `capture.mjs` reproduces the snapshots from GitHub issue and timeline APIs. It
  refuses issues with title/body edit events because the original content cannot
  be reconstructed reliably.
- `materialize-trial.mjs` creates a single-case, staged trial workflow with the
  frozen snapshot embedded.
- `score.mjs` scores agent output and optional persisted after-state evidence.
- `aggregate.mjs` scores repeated `gh aw trial` results and reports per-case
  pass rates and decision variance.
- `proof.json` records the bounded staged runs used for red/green proof.
- `repeat-proof.json` records the final repeated full-corpus results and run
  URLs.

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

Aggregate repeated trial results:

```bash
node .github/workflows/issue-triage-eval/aggregate.mjs trials \
  issue-triage-repeat- > /tmp/issue-triage-repeat-proof.json
```
