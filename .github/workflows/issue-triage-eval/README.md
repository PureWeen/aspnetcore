# Issue triage replay evaluation

This directory contains the frozen public issue-triage benchmark for
`dotnet/aspnetcore`. It captures a narrow, point-in-time set of public issue
snapshots and evaluates the issue-triage workflow contract offline without
relying on workflow execution or persisted live evidence.

The corpus intentionally covers only:

- exactly one top area label;
- issue type;
- at most one supported subtype;
- removal of `needs-area-label`;
- curated duplicate citations;
- abstention when a valid no-op is needed; and
- valid, explicitly targeted safe-output requests.

It intentionally excludes severity, affected count, milestones, closure,
resolution, servicing, feature-family labels, and second-area ownership.

## Files

- `cases.json` defines the accepted outputs, evidence URLs, and scoring
  exclusions for each frozen case.
- `snapshots/*.json` stores the public issue payloads and source hashes for the
  11 point-in-time snapshots.
- `capture.mjs` regenerates the snapshot corpus from public GitHub issue and
  timeline APIs. It refuses issues whose title or body changed after capture,
  because the original public state cannot be reconstructed reliably.
- `score.mjs` deterministically scores a single exported `agent_output.json`
  against the frozen case.
- `score.test.mjs` exercises the scorer with representative pass/fail examples.
- `aggregate.mjs` aggregates repeated offline scoring results and reports
  per-case pass rates and decision variance.
- `README.md` documents the frozen corpus and offline scoring contract.

## Capture and regeneration

```bash
node .github/workflows/issue-triage-eval/capture.mjs
```

This tool reads only public issue and timeline data and preserves the frozen
snapshots as a public-data benchmark. The snapshots are intentionally limited to
public issue state and are not a claim about live maintainer triage behavior.

## Deterministic per-run scoring

```bash
node .github/workflows/issue-triage-eval/score.mjs \
  67614-startup-failure \
  /path/to/agent_output.json

node --test .github/workflows/issue-triage-eval/score.test.mjs
```

The scorer checks exactly the issue-triage contract above and produces a stable
pass/fail result for one run. It is deterministic by design and should be used
for offline evaluation only.

## Repeated-result aggregation

```bash
node .github/workflows/issue-triage-eval/aggregate.mjs \
  /path/to/trial-results
```

This tool aggregates repeated offline run results and reports per-case pass rates,
decision variance, and summary statistics. It is a reporting tool only; it does
not stage or execute the workflow.

## Intended contract and exclusions

This corpus is a replay and scoring harness for issue-triage outputs. It is
intended to validate structural triage decisions and safe-output targeting, not a
live workflow run, recorded evidence artifact, or persistence test. Later stack
layers may add staged workflow execution and recorded evidence, but this layer
focuses only on the frozen corpus and offline scoring logic.

## Public-data safeguards

- Only public `dotnet/aspnetcore` issue data is included.
- Snapshots are point-in-time and preserved with source hashes.
- The scorer never depends on private metadata, hidden workflow state, or live
  repository state.
- This directory intentionally excludes workflow execution proof, replay lanes,
  and staging artifacts that would claim live execution or recorded evidence.

