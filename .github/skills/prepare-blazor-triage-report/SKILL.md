---
name: prepare-blazor-triage-report
description: >-
  Prepare concise, evidence-backed, read-only readiness reports for the Blazor
  triage team. Use whenever someone asks to pre-triage open issues labeled
  "investigate", prepare twice-weekly Blazor triage meeting material, assess
  whether a Blazor report includes a usable reproduction, compare a reported
  reproduction with a vanilla Blazor template, or pre-evaluate an unevaluated
  community or vendor Blazor pull request. Produce a practical report that
  helps a human decide the next step; do not mutate GitHub issues, pull
  requests, labels, comments, projects, or repository files. Do not use for
  full implementation, a final code review, or posting triage decisions.
---

# Prepare Blazor triage reports

Turn the items a triager may need to read into short, evidence-backed meeting
material. The report should reduce initial investigation time, not make a
decision on behalf of the triage team.

## Inputs

Accept one or more issue/PR numbers or URLs, or a request to discover a bounded
queue. For discovery, accept a repository, maximum item count, and any known
community/vendor author list or triage query. Default to `dotnet/aspnetcore`
and a small oldest-first batch when the request does not specify them. Request
the reproduction repository/attachment link if an issue has one but GitHub
does not expose it.

## Scope and safety

- Use only read-only GitHub operations. `gh issue view/list`, `gh pr view/list`,
  `gh api` GET requests, GitHub search, and repository reads are appropriate.
- Do not add or remove labels, comment, review, close, assign, edit a project,
  push, create a branch, or change repository files.
- Never execute reporter-provided code. If examining a reproduction locally,
  read its files and generate a comparison template only in a disposable
  scratch directory outside the repository.
- Separate facts from inferences. Link every material claim to its issue, pull
  request, source path, commit, documentation, or search result. Say
  **Not established** when evidence is absent.
- Treat the output as meeting preparation, not a resolution, severity
  assessment, security review, API approval, or merge recommendation.

## Choose the report mode

Ask for issue or PR numbers/URLs when they are not supplied. A batch is fine;
process each item independently and include an index at the top.

| Mode | Use when | Target selection |
|---|---|---|
| **Investigate issue** | An open issue has the `investigate` label or is supplied for investigate-label pre-triage. | Default repository: `dotnet/aspnetcore`. Use the supplied fork only when requested. For the normal meeting queue, list open `area-blazor` issues with `investigate`, no milestone, then exclude `Needs: Author Feedback`, `Resolution: Answered`, and `Resolution: Duplicate`. Sort oldest first. |
| **Community/vendor PR** | A community or vendor PR needs its first structured evaluation. | Prefer supplied PRs. If discovering candidates, use the provided author/vendor list or repository triage query. Do not guess an author's affiliation from a display name. Check the PR description, reviews, and comments for an existing structured evaluation before reporting it as unevaluated. |

The normal Blazor triage query is a starting point, not a replacement for the
`investigate` queue:

```text
is:issue is:open no:milestone label:area-blazor
-label:"Needs: Author Feedback"
-label:"Resolution: Answered"
-label:"Resolution: Duplicate"
sort:created-asc
```

Use GitHub's actual label names returned by the repository. If the query syntax
cannot express a filter, retrieve the candidates and state the client-side
filter used in the report.

## Workflow for investigate issues

1. Read the issue body, labels, timeline, linked issues/PRs, attachments, and
   referenced repository. Record the reporter's claimed behavior, expected
   behavior, affected render mode/hosting model, framework version, browser,
   and smallest stated steps to reproduce. Do not fill in missing details by
   inference.
2. Check whether `area-blazor` is a reasonable routing label. Name the specific
   component boundary that supports the conclusion, such as Components,
   Razor, WebAssembly, server circuits, forms, routing, or JavaScript
   interop. If evidence instead points to a different ASP.NET Core area or
   cannot identify an owner, say so plainly.
3. Classify the reproduction:

   | Classification | Meaning |
   |---|---|
   | **Runnable repository** | Source and instructions are available and the scenario appears sufficiently self-contained to inspect. |
   | **Partial repository** | Files exist, but important project, version, configuration, or reproduction steps are missing. |
   | **Snippet only** | The report contains code but no inspectable project. |
   | **No reproduction** | No code or reliable steps are supplied. |

   This classifies completeness, not whether the reported behavior reproduces.
4. For a runnable or partial Blazor repository, perform a template-diff
   analysis only when a suitable vanilla template can be identified:
   - Read the repro's target framework, SDK, hosting model, and project shape.
   - Generate the closest matching `dotnet new` Blazor template in a
     disposable directory. Use the repo SDK when it is available, and record
     the template command and SDK version.
   - Compare source and project files while excluding build outputs,
     `bin`, `obj`, package lock artifacts, and generated files.
   - Summarize only the changes that could affect the report: application
     startup/configuration, render modes, components/pages, routing, services,
     packages, JavaScript/CSS, and explicit environment settings.
   - Do not claim a template diff when the template, SDK, or hosting model
     cannot be matched. State the mismatch and provide a concise inventory of
     the supplied files instead.
5. Search the same technical area for prior issues and PRs. Prefer semantic
   search over dotnet repository discussions (for example,
   `mihubot-search_dotnet_repos`) using the symptom, component boundary, and
   relevant exception/message. Also search code and docs when they can explain
   expected behavior. Include only the few strongest matches and explain their
   relationship; a keyword overlap alone is not a duplicate.
6. Look for documented limitations, supported render modes, configuration
   requirements, and known patterns in official docs and the repository.
   Distinguish a documented behavior from an unverified hypothesis.
7. End with one suggested next action:
   - **Needs more information** — identify the exact missing version, minimal
     reproduction, logs, expected result, or steps.
   - **Looks actionable** — identify the suspected component boundary and the
     evidence that makes it worth investigation.
   - **Possibly by design** — link the behavior or documentation that supports
     this, and state what would disprove it.
   - **Possible duplicate** — link the prior item and name the facts that need
     confirmation before treating it as a duplicate.

## Workflow for community/vendor PRs

1. Read the PR description, linked issues, changed files, commits, checks,
   review state, and relevant conversation. Identify the issue addressed; if
   none is linked, say **No linked issue identified**.
2. Summarize the change at the level needed for triage: affected runtime or
   tooling area, old versus new behavior, and the main implementation path.
   Trace only enough surrounding code to assess whether the proposed fix is
   connected to the reported problem.
3. Assess correctness and completeness as a preliminary evaluation:
   - Does the change plausibly address the linked report?
   - Are error paths, relevant render modes, configuration variants, and
     compatibility implications considered?
   - Is the implementation consistent with nearby code and existing repository
     conventions?
   - Are tests present, targeted, and meaningfully related to the change?

   State gaps as questions for the reviewer, not defects, unless the diff
   provides direct evidence.
4. Assign a risk level based on observable change scope:

   | Risk | Typical signals |
   |---|---|
   | **Low** | Isolated bug fix with targeted coverage and no public or behavioral contract change. |
   | **Medium** | Behavior or configuration changes, broad component impact, incomplete coverage, or interaction across render modes. |
   | **High** | New or changed public API, breaking behavior, compatibility-sensitive protocol/serialization changes, security boundary, or broad framework impact. |

   Explain the specific signal. New public API requires API-review attention;
   this report identifies that need but does not substitute for API review.
5. Check for an earlier structured evaluation in review comments, linked issues,
   or a clearly equivalent triage report. If one exists, link it and summarize
   only what remains unresolved rather than duplicating it.
6. End with a practical recommended next action, such as request targeted
   coverage, route to API review, confirm compatibility expectations, assign a
   component reviewer, or proceed to normal code review.

## Report format

Use this compact format for each item. Keep the main report scannable in a
meeting; put raw commands, full diffs, and search receipts in a collapsed
details section or an optional appendix.

```markdown
# Blazor triage report: <issue-or-PR-number> — <title>

**Mode:** Investigate issue | Community/vendor PR
**Prepared:** <UTC date>
**Evidence reviewed:** <links>

## Summary
<2-4 sentences stating the claim/change and the current confidence.>

## Readiness
| Check | Finding | Evidence |
|---|---|---|
| Reproduction / linked issue | ... | ... |
| Area routing / implementation fit | ... | ... |
| Tests | ... | ... |
| Risk | Low / Medium / High — reason | ... |

## Template-diff analysis
<For issues with an eligible repo: template, command/SDK, and meaningful edits.
Otherwise: Not applicable — reason.>

## Related history and guidance
- <strong related issue/PR/doc and why it matters>

## Suggested next action
**<one disposition>:** <specific action and any question to resolve.>

## Limits
<Missing access, unavailable repro, unverified behavior, or no material limits.>
```

For issue reports, write **Tests** as **Reproduction completeness** and
**Risk** as **Impact clues** when those labels better fit the evidence. For PR
reports, omit the template-diff section unless the PR's reproduction changes
make it directly relevant.

## Output

Return the Markdown report as the primary artifact. A short optional receipt
listing the query, sources read, template command, and search terms is useful
for repeatability, but do not let it displace the human-readable report.

## Completion criteria

The report is ready when it gives a triager a concise claim/change summary,
evidence-backed routing and completeness signals, the strongest relevant
history, clearly scoped uncertainty, and one practical next action without
changing any GitHub or repository state.
