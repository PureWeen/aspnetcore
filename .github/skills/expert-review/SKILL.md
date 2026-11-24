---
name: expert-review
description: >-
  Reviews an ASP.NET Core PR or diff with domain-expert depth. Routes each changed area to
  its specialized reviewer agent and runs a parallel, one-subagent-per-dimension review with
  a briefing pack, validation, and consolidated findings. Use to review ASP.NET Core changes,
  PRs, or diffs across Kestrel/servers/networking, MVC/Razor/routing, Blazor/Components,
  SignalR, auth/security/identity/DataProtection, hosting/DI, minimal APIs/OpenAPI, gRPC,
  native IIS/ANCM interop, or any other src area.
---

# Expert review

Review an ASP.NET Core PR or diff with domain-expert depth: route each changed area to its
reviewer agent, then evaluate that agent's review dimensions as parallel subagents. The agents
own the domain dimensions and CHECK items; this skill owns the routing and the workflow.

## 1. Route

Map each changed path to its reviewer agent. The agent holds the review dimensions.

| Changed paths | Reviewer agent |
|---|---|
| `src/Servers`, `src/Http`, `src/Middleware`, `src/HttpClientFactory`, `src/HealthChecks`, `src/Extensions` | `@servers-networking-reviewer` |
| `src/Mvc`, `src/Razor`, `src/Html.Abstractions` | `@mvc-razor-routing-reviewer` |
| `src/Components` | `@blazor-components-reviewer` |
| `src/SignalR` | `@signalr-reviewer` |
| `src/Security`, `src/Identity`, `src/DataProtection`, `src/Antiforgery`, `src/WebEncoders` | `@auth-security-reviewer` |
| `src/Hosting`, `src/DefaultBuilder` | `@hosting-di-reviewer` |
| `src/Http` (minimal APIs), `src/OpenApi` | `@minimal-api-openapi-reviewer` |
| `src/Grpc` | `@grpc-reviewer` |
| `src/Servers/IIS`, `src/Installers` | `@native-interop-reviewer` |
| **every change** — cross-cutting: API/compat, nullability, async/cancellation, perf/allocations, disposal, options, trimming/AOT, security, tests | `@cross-cutting-reviewer` |

**Always run `@cross-cutting-reviewer`** on every review, in addition to the matched area
reviewer(s) — its dimensions apply to all changes, and it is the primary reviewer for any area
without a dedicated agent. `src/Http` and `src/Servers` are shared: route to both matching agents.
Folder-scoped `.github/instructions/*.instructions.md` carry the same routing on file edits.

## 2. Brief — build the briefing pack

Assemble once and give it to every dimension subagent:
- The correct PR diff **against the merge base** (`gh pr diff <n> --repo <owner>/<repo>`); never `git diff main` — new files exist only on the PR branch.
- PR description, linked issues/specs, and the changed-files list.
- **All existing feedback**, so you never restate it: inline review comments in **both unresolved and resolved** threads, PR-level review summaries, and prior automated or human reviews (Copilot code review, community reviewers). Resolved threads still count — the point was already made. Fetch it with `gh api` (review comments, reviews, and their reactions).
- **The coverage map**: which reviewer agents are running this review and their dimensions (always including `@cross-cutting-reviewer`). Give it to every subagent so each stays in its own dimension, does not re-report a peer's or the cross-cutting reviewer's finding, and can flag a gap it notices outside its lane.

## 3. Find — parallel, one subagent per dimension

**This workflow requires delegation.** Do not perform a direct review first. Immediately call each
routed reviewer with the `task` tool, even for a small diff.

For each routed area, call the `task` tool with `agent_type` set to that reviewer agent's name
(for example `blazor-components-reviewer`, `cross-cutting-reviewer`). Launch the routed agents in
parallel. Give each one the briefing pack, and include this sentence verbatim in its prompt:
"The expert-review skill requires that you call `task` (agent_type `explore`) once per review dimension
listed in your instructions, in parallel batches of ~6. Each dimension is a separate bounded
objective; these are not duplicate agents for the same objective."
Each dimension subagent evaluates exactly one
dimension against the PR diff and returns `LGTM` or a concrete finding with an exact `file:line`
and a specific failing scenario (input, call sequence, or state). No hypotheticals, nitpicks, style,
typos, or spelling — only real bugs; read the PR branch, not `main`. In each reviewer prompt, require
the reviewer to return its per-dimension results, how many dimension subagents it launched, and any
dimension whose subagent failed with the exact `task` error (or that no error detail was returned).

Use the manual fallback only if the `task` tool is unavailable in this host, a routed reviewer
`task` call returns an error, or a reviewer reports that a dimension subagent failed. Note the
exact error, that no error detail was returned, or that `task` is unavailable in your session
output, then read the affected agent's `.md` and work through all its `## Review dimensions` after
a routed reviewer failure, or only the failed dimensions after a dimension subagent failure. Never
skip delegation pre-emptively. A reviewer that omits required results or failure reporting is
incomplete; stop rather than silently reviewing its dimensions directly.

## 4. Validate

For each non-LGTM finding, prove or disprove it by tracing the code flow on the PR branch or
writing a minimal test. Keep only findings backed by concrete evidence.

## 5. Consolidate and post

Post each confirmed finding as an inline comment anchored to the exact `file:line` on the PR diff,
so it can be resolved and replied to. **A finding with no `file:line` is not a finding** — if you
cannot name the file and line, you have not reviewed it; drop it. (Exceptions: the all-clear comment
below, and an **issue-closure gap** — a behaviour the issue requires that the diff leaves unclosed,
including a change the fix should have made in an **unchanged** owner; put it in the summary, citing the
unchanged `file:line` it should have addressed.) **Deduplicate against all existing feedback first** (resolved and
unresolved, from any reviewer or bot): if a finding is already raised, do **not** post a duplicate —
add a 👍 reaction to that comment (`gh api ... /reactions`), and reply only if you can add concrete
new evidence. Post only genuinely new findings. **Only post feedback you have
verified in code** — reproduced the failure or tried the fix. Solid bugs only; never post nitpicks,
typos, spelling, or style. If you are not certain it is a real bug, drop it.

Every inline comment opens with the signature **🕵️ 🤖** and is concise, precise, and code-heavy
with minimal prose — never a wall of text:

- **🕵️ 🤖 one-line claim of the bug** (nothing more on the first line).
- A minimal **repro in consumer code** — the smallest ASP.NET Core user/app code, client call, or config that reaches this line and triggers the flaw. Do **not** paste the framework code at the anchor; the diff already shows it.
- What goes wrong: the specific failing behavior, in ≤2 lines or a tiny trace.
- A **fix as a code snippet/diff** when possible, not a paragraph.

Template:

````md
🕵️ 🤖 **Handshake timeout not enforced before dispatch**

Repro — a client that connects but never completes the handshake:
```csharp
var ws = new ClientWebSocket();
await ws.ConnectAsync(hubUri, default);   // then send nothing
```
The server holds the connection and its buffers until the socket drops — the read at this line has no timeout.
Fix:
```csharp
using var cts = new CancellationTokenSource(options.HandshakeTimeout);
var msg = await ReadHandshakeAsync(input, cts.Token);
```
````

**All clear.** If nothing significant is found, post no inline comments — post one top-level comment
instead (the only comment allowed without a `file:line` anchor):

```
🕵️ 🤖 LGTM ✅

Agents used: [servers-networking-reviewer](.github/agents/servers-networking-reviewer.md), [signalr-reviewer](.github/agents/signalr-reviewer.md)
```

Link each agent you used to its definition file. Otherwise close with a one-line-per-dimension
summary (`LGTM` or `<n> findings`). Design concerns, and **issue-closure gaps** (a required behaviour left
unclosed, or an implicated **unchanged** owner the fix should have modified — cite the unchanged `file:line`),
go in that summary as one bullet each — still no walls of text.
