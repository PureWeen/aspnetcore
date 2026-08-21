---
name: assess-issue-readiness
description: >-
  Assess whether a canonical dotnet/aspnetcore issue is ready to begin fix
  investigation without re-triaging it, judging the issue's general validity, or
  proposing a fix. Use this skill when an ASP.NET Core maintainer asks whether an
  existing issue has enough supported-usage and executable evidence to hand off
  for fix investigation, needs reporter evidence, reflects invalid setup or
  unsupported usage, is already resolved or duplicate, needs a product/docs
  decision, or should stop below an investigation threshold. Produces a validated
  local readiness receipt. Never use it for other repositories, implementation,
  GitHub mutation, or upstream triage replacement.
compatibility: Requires a local aspnetcore checkout, Python 3, git, and an externally enforced no-mutation execution boundary for hard guarantees
---

# Assess ASP.NET Core issue readiness

Readiness means **readiness to begin fix investigation**. It is not general issue
triage, a judgment that the report is valid or invalid, permission to close an
issue, or a fix proposal.

Consume existing upstream triage, perform the smallest proportionate
setup/support/history/reproduction assessment, and produce one auditable route or
stop disposition.

## Scope and boundaries

- Support only canonical `https://github.com/dotnet/aspnetcore/issues/<n>` issues.
- Never assign or re-derive labels, type, milestone, ownership, severity, or
  product intent. Record missing upstream signals as missing.
- Never comment, edit, label, assign, close, reopen, transfer, dispatch, push,
  create, or otherwise mutate any GitHub resource.
- Never write to Microsoft 365.
- Do not add or invoke a workflow.
- Do not propose or implement a fix. A ready result ends at `fix_investigation`.
- Preserve the user's source worktree. Reproduction writes belong only in
  explicitly recorded disposable worktree, artifact, cache, and temp roots.
- Stop immediately on vulnerability-report indicators. Do not assess or reproduce
  them; route to the established security reporting process.

## Safety model

The prompt, receipt, validator, and command regexes are **attestation and
consistency checks**, not a sandbox. They can reject a receipt that records a
mutation, but cannot prevent a host-exposed write tool or credential from being
used outside the recorded command list.

A hard no-remote-mutation guarantee exists only when the caller launches the
entire acquisition and assessment in an OS/container boundary that:

1. exposes no GitHub or Microsoft 365 write-capable tools;
2. contains no GitHub, Azure DevOps, Microsoft 365, SSH, or other remote-write
   credentials;
3. permits acquisition only through the bundled unauthenticated GET-only harness;
4. disables external network after acquisition; and
5. restricts filesystem writes to the receipt's authorized roots.

Set `safety.hard_no_mutation_guarantee` to `true` only when that external condition
is actually enforced. A normal interactive host with write-capable tools or
credentials must use `execution_boundary: host_attestation` and set the hard
guarantee to `false`, even if every recorded action was read-only.

## Acquire immutable public input

Prefer the bundled harness because it has one deterministic remote capability:
unauthenticated HTTPS GET to public `api.github.com` issue endpoints.

```bash
python3 .github/skills/assess-issue-readiness/scripts/acquire_public_issue_snapshot.py \
  <issue-number> <artifact-root> [--related-issue <number> ...]
```

It writes the issue, comments, optional related issues, and a hashed acquisition
manifest beneath `<artifact-root>/evidence/`. It does not read environment tokens
or accept arbitrary URLs. After acquisition, remove external network access and
perform assessment from those files.

Unauthenticated GitHub API access is rate-limited (commonly about 60 requests per
hour, subject to GitHub policy). Keep acquisitions bounded, reuse a frozen snapshot
for the same issue revision, and cache related-issue evidence under the same
artifact root. Do not add authenticated tokens merely to increase this budget.

An already supplied public snapshot may use `provided_offline_snapshot`; record
its provenance and hashes. Do not fetch missing triage signals during offline
assessment. Report them as missing.

## Required inputs

1. Canonical dotnet/aspnetcore issue number or URL.
2. Absolute artifact root outside the repository.
3. Local aspnetcore source worktree path and assessed SHA.
4. Safety mode and authorized writable roots.
5. Optional maintainer depth override.

Freeze title, body, state, state reason, labels, type, milestone, relevant
comments, and `updated_at`. The issue revision is the observed `updated_at`, state,
and state reason. A later issue change requires a new receipt.

## Investigation tiers

Advance only while the preceding tier leaves readiness unresolved.

| Tier | Purpose | Default budget |
|---|---|---|
| 0 | Consume the frozen issue and upstream triage | 10 minutes |
| 1 | Check setup completeness against supported docs/templates | 15 minutes |
| 2 | Verify supported usage and focused history/docs | 20 minutes, 5 searches |
| 3 | Run a released-SDK standalone repro | 30 minutes, 2 execution attempts |
| 4 | Use an in-tree build only for unreleased/in-tree claims | 45 minutes, 1 targeted build/test surface |

These progressive tiers make deep investigation optional: stop as soon as a
higher-precedence disposition is supported. Budgets are ceilings. Record exhausted
budgets as blockers. High customer/release signal may justify advancing one tier
or a maintainer-approved extension. Low signal may produce
`deferred_below_threshold`; it does not alter factual findings.

## Reproduction and isolation

1. Prefer a minimal standalone app on the released SDK/TFM named by the reporter.
2. Use an in-tree build only for unreleased behavior, repository-only assets, or a
   necessary released/in-tree comparison. Activate the repository SDK first.
3. Treat reporter projects and build files as untrusted executable input. Inspect
   them, copy only required inputs into the sandbox, and remove credentials.
4. Deny **external** network during build/run/assessment. Loopback is separate:
   permit only explicitly recorded localhost traffic needed between the test app
   and browser. Interactive Blazor validation requires loopback.
5. Authorize only these writable roots: artifact root, optional disposable
   worktree, and explicit cache/temp roots. They must not equal, contain, or be
   contained by the user's source worktree.
6. Run reproduction and in-tree commands beneath an authorized writable root,
   never the user's source worktree.
7. When executable runtime evidence is feasible, source inspection alone cannot
   produce `ready_for_fix_investigation`.
8. A bounded failed reproduction yields `not_reproduced`, never closure.
9. For Components/Blazor behavior, invoke `validate-blazor-feature` inside the
   disposable worktree for sample/render-mode/browser mechanics. Import its
   evidence rather than duplicating it.

If the required sandbox, loopback policy, or writable roots cannot be established,
do not execute the repro. Record `infrastructure_blocked`.

## Decision procedure

Read [references/disposition-policy.md](references/disposition-policy.md). Set each
decision signal from cited evidence, evaluate the ordered table, and select exactly
one primary disposition. Keep lower-precedence observations in
`supporting_findings`.

Confidence is confidence in the route:

- `high`: direct upstream decision or repeatable executable evidence.
- `medium`: consistent primary-source evidence with a bounded gap.
- `low`: material missing evidence or an environmental blocker.

`ready_for_fix_investigation` routes neutrally to `fix_investigation`. If an
`aspnetcore-try-fix` implementation is installed, a maintainer may choose it for
that later stage; this receipt never depends on that external skill.

## Receipt and validation

The human-readable decision, reason, and next route are the primary maintainer
output. The JSON receipt is the audit artifact that binds those fields to frozen
evidence and validator checks.

Write `<artifact-root>/receipt.json` using
[references/readiness-receipt.schema.json](references/readiness-receipt.schema.json).
Use artifact-root-relative evidence paths with SHA-256 hashes. Record every
command, including failures, and make `check_summary` match `checks`.

```bash
python3 .github/skills/assess-issue-readiness/scripts/validate_readiness_receipt.py \
  <artifact-root>/receipt.json
```

The validator checks schema, deterministic disposition precedence, evidence files
and hashes, safety-mode consistency, neutral routing, authorized writable roots,
runtime command locations, loopback requirements, and contradictions in recorded
commands. Recorded commands must be direct, inspectable invocations; inline shell
or language evaluator wrappers are rejected rather than recursively interpreted.
These checks do not create the external execution boundary.

Keep the current disposition names as internal routing outcomes. Some encode
existing upstream decisions rather than assessor judgments; taxonomy simplification
is a separate maintainer/design decision and is not part of this hardening pass.

## Output

```markdown
# Issue readiness assessment

**Issue:** dotnet/aspnetcore#<number> @ <updated_at>
**Assessed SHA:** <sha>
**Ready to begin fix investigation:** yes / no
**Primary disposition:** <disposition>
**Confidence:** <confidence>
**Reason code:** <reason_code>
**Next route:** <next_route>
**Hard no-mutation guarantee:** yes / no

## Evidence
- <decisive evidence references>

## Supporting findings
- <finding or "None">

## Missing evidence and blockers
- <item or "None">

**Receipt:** <absolute local path>
**Recorded remote mutations:** None
```
