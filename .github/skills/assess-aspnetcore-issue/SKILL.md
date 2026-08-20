---
name: assess-aspnetcore-issue
description: >-
  Assess whether an existing dotnet/aspnetcore issue is actionable for fix
  investigation without re-triaging it or proposing a fix. Use this skill when a
  maintainer asks whether an ASP.NET Core issue is ready to investigate, needs a
  reporter repro, reflects unsupported or invalid setup, is already fixed or
  duplicate, is a documentation/design question, or should stop for insufficient
  evidence. Produces a validated local assessment receipt and routes only
  evidence-ready issues to aspnetcore-try-fix. Never use it to implement a fix,
  mutate GitHub, or replace upstream triage.
compatibility: Requires a local aspnetcore checkout, Python 3, git, and read-only GitHub access
---

# Assess ASP.NET Core issue actionability

Act as an issue-side front door. Consume upstream triage signals, perform the
smallest proportionate investigation, and produce one auditable disposition.
Do not propose or implement a fix.

## Non-negotiable boundaries

- Support only issues whose canonical source is `dotnet/aspnetcore`.
- Treat GitHub as read-only. Use only GET/read/list/search operations. Never
  comment, edit, label, assign, close, reopen, transfer, dispatch, push, or create
  any GitHub resource.
- Do not write to Microsoft 365.
- Do not add or invoke a workflow. This skill is maintainer-invoked and local.
- Preserve user changes. Put any generated repro in a disposable directory or
  isolated worktree.
- Treat reporter-provided projects and build files as untrusted code. Execute them
  only in a sandbox with GitHub/Microsoft 365 credentials removed, network disabled,
  and writes restricted to the artifact root. If that isolation is unavailable,
  record an infrastructure blocker instead of running the repro.
- Put every generated log, downloaded issue snapshot, repro, and receipt beneath
  one caller-selected artifact root outside the repository. Never scatter evidence
  across the checkout.
- Stop immediately on vulnerability-report indicators. Do not assess exploitability
  or reproduce the report; route it to the existing security reporting process.
- Never infer absent upstream triage. Record missing labels, type, milestone, or
  maintainer decisions in `upstream_triage.missing_signals`.

## Required inputs

1. Issue number or canonical `https://github.com/dotnet/aspnetcore/issues/<n>` URL.
2. Absolute local artifact root outside the repository.
3. Local aspnetcore checkout to inspect and its assessed SHA.
4. Optional maintainer depth override. Without one, use the proportionality policy.

Resolve the issue only with read-only retrieval. Freeze the issue title, body,
state, state reason, labels, type, milestone, comments needed as evidence, and
`updated_at`. The receipt's issue revision is this observed `updated_at` plus the
state and state reason. If the issue changes later, produce a new receipt.

## Investigation tiers

Advance only while the preceding tier leaves a decision unresolved.

| Tier | Purpose | Default budget |
|---|---|---|
| 0 | Freeze issue revision and consume upstream triage | 10 minutes |
| 1 | Check setup completeness against supported docs/templates | 15 minutes |
| 2 | Verify supported usage and search focused history/docs | 20 minutes, 5 focused searches |
| 3 | Run a released-SDK standalone repro | 30 minutes, 2 execution attempts |
| 4 | Use an in-tree build only for unreleased or explicitly in-tree claims | 45 minutes, 1 targeted build/test surface |

Budgets are ceilings, not targets. Record exhausted budgets as blockers rather
than continuing open-ended investigation. High customer/release signal may justify
advancing one tier or a maintainer-approved extension. Low signal may stop as
`deferred_below_threshold`; it never changes factual findings.

## Reproduction policy

1. Prefer a minimal standalone app on the released SDK/TFM named by the reporter.
   Preserve the exact SDK, TFM, OS, commands, logs, and repro source.
2. Use an in-tree build only when the claim concerns unreleased behavior,
   repository-only assets, or a released-SDK comparison requires it. Activate the
   repository SDK before any `dotnet` command.
3. When executable runtime evidence is feasible, source inspection alone cannot
   produce `ready_for_fix_investigation`.
4. A failed reproduction attempt yields `not_reproduced`, not closure. Record
   environment differences and the evidence that would change the result.
5. For Components/Blazor behavior, invoke `validate-blazor-feature` for sample
   choice, launch, port, render-mode, browser, console, and network mechanics.
   Import its evidence into this receipt; do not duplicate that workflow.
6. Do not change product code or create a candidate fix. A successful reproduction
   ends this skill and routes to `aspnetcore-try-fix`.
7. Never run arbitrary reporter scripts on the host. Copy only the minimal repro
   inputs into the sandbox, inspect project/build files first, and attest the
   isolation fields in `safety`.

## Decision procedure

Read [references/disposition-policy.md](references/disposition-policy.md) before
deciding. Set every `decision_signals` value from cited evidence, select exactly
one primary disposition using the ordered table, and keep secondary observations
in `supporting_findings`.

Confidence means confidence in the selected route, not confidence that the product
has a bug:

- `high`: direct upstream decision or repeatable executable evidence.
- `medium`: consistent primary-source evidence with a bounded gap.
- `low`: material missing evidence or an environmental blocker.

Blockers and missing evidence are required arrays. Use explicit entries rather
than optimistic defaults.

## Receipt

Write `<artifact-root>/receipt.json` using
[references/receipt.schema.json](references/receipt.schema.json). Keep all evidence
paths relative to the artifact root and include SHA-256 hashes. Record every
command, including failures, and make `check_summary` exactly match `checks`.

Validate before reporting:

```bash
python3 .github/skills/assess-aspnetcore-issue/scripts/validate_receipt.py \
  <artifact-root>/receipt.json
```

Do not hand-edit a receipt to force a disposition. Correct the underlying signals
or evidence.

## Output

Return the receipt path plus this concise summary:

```markdown
# Issue actionability assessment

**Issue:** dotnet/aspnetcore#<number> @ <updated_at>
**Assessed SHA:** <sha>
**Primary disposition:** <disposition>
**Confidence:** <confidence>
**Reason code:** <reason_code>
**Next route:** <next_route>

## Evidence
- <decisive evidence references>

## Supporting findings
- <finding or "None">

## Missing evidence and blockers
- <item or "None">

**Receipt:** <absolute local path>
**Remote mutations:** None
```

`ready_for_fix_investigation` routes to `aspnetcore-try-fix`. Only a later
resulting diff may enter a diff-review workflow. All other dispositions stop or
route to the named evidence, documentation, design, infrastructure, or security
owner.
