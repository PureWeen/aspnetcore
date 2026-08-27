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
- `score.mjs` scores a single exported `agent_output.json` against the frozen
  contract.
- `aggregate.mjs` scores repeated result exports and reports per-case pass rates
  and decision variance.
- `score.test.mjs` verifies the deterministic scoring contract and safety checks.

This layer intentionally ships only the frozen public corpus and the offline
scoring tools. Later stack layers will supply staged workflow execution and
recorded evidence from the replay lane.

## Run

Refresh the snapshots:

```bash
node .github/workflows/issue-triage-eval/capture.mjs
```

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
