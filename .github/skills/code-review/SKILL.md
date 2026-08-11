---
name: code-review
description: >-
  Repository-specific review checks for dotnet/aspnetcore pull requests. USE FOR
  reviewing a diff or pull request in this repository, to catch ASP.NET Core
  conventions a general-purpose reviewer misses: public API baseline files
  (PublicAPI.Shipped.txt / PublicAPI.Unshipped.txt), servicing and release-branch
  rules, shared-framework and trimming project lists, Arcade-owned paths, new
  diagnostic IDs, quarantined tests, and Components test placement. Also covers
  when to stay quiet on dependency-flow, mirror, and generated-file pull requests.
  Read-only: analysis and review comments only. DO NOT USE FOR building or testing
  the repository, or for designing the shape of a new public API (use
  review-public-api).
---

# ASP.NET Core code review

Repository conventions that a general-purpose reviewer cannot infer. Apply these
in addition to normal review.

## How to use this skill

Every check here is decided by **reading files**, not by building or running
anything. A review of this repository cannot compile it or run its tests in the
time a review takes, so no check below asks for compilation, test execution, or
red/green proof.

Each check has the same shape: the diff changes one thing, so open a specific
other file and confirm it agrees. That cross-file comparison is the part a
reviewer working from the diff alone cannot do, and it is where this skill earns
its place — the file that proves the defect is usually a file the pull request
did not touch.

Two limits to respect:

- Comment only when a file you actually read supports the claim. Cite it by path.
- If a concern depends on runtime behavior — concurrency, lifecycle, transport,
  browser — say it needs verification instead of asserting it. Do not imply a
  test was run.

Do not restate style rules already enforced by `.editorconfig` and the repo
analyzers, and do not repeat what the build will report anyway.

If you check only one thing, check the public API baselines.

## 1. Public API baselines

Public API is tracked in `PublicAPI.Shipped.txt` / `PublicAPI.Unshipped.txt`
next to each shipping `src` project. See `docs/APIBaselines.md`.

When the diff changes a public type or member, open the `PublicAPI.Unshipped.txt`
beside that project and confirm it matches:

- New public API needs a matching entry.
- A **changed** API — including a nullability change — needs **two** entries: a
  `*REMOVED*` line for the old signature and a line for the new one. A diff that
  adds only the new line is incomplete. This is the most common miss.
- Removed public API needs a `*REMOVED*` entry.
- Entries are exact signatures. A rename, a parameter type change, or an added
  default all change the signature.

Related checks:

- **`PublicAPI.Shipped.txt` changes need a stated reason.** `docs/APIBaselines.md`
  says it "should only be modified after a major release by the build team and
  should never be modified otherwise." Legitimate exceptions exist — marking a
  released version as shipped, baseline resets, and merge-conflict repair — so
  ask why rather than asserting the change is wrong. Do not raise it on a pull
  request whose stated purpose is a baseline update.
- New shipping `src` projects need both baseline files, copied from
  `eng/PublicAPI.empty.txt` — or `<AddPublicApiAnalyzers>false</AddPublicApiAnalyzers>`
  for non-shipping and test-only projects. The default is on for `src` projects
  outside `Tools` (`eng/targets/CSharp.Common.targets`).
- Whether a *new* API is well-shaped is a separate question. Defer to the
  `review-public-api` skill and the `api-ready-for-review` process
  (`docs/APIReviewProcess.md`) instead of redesigning it inline.

## 2. Servicing and release branches

Check the base branch first. If it is `release/*`, apply `docs/Servicing.md`:

- Patches **cannot** add, remove, or change public API — apps must stay
  binary-compatible across every patch of a major.minor. Any API change on a
  `release/*` pull request is a finding, even a correct-looking one.
- Servicing pull requests need the servicing template filled in and are gated on
  Shiproom review. An empty template is worth one comment.

## 3. Paths owned by other repositories or by automation

- **`eng/common/**` is owned by Arcade.** Per `eng/common/AGENTS.md`, edits there
  "will be overwritten by automation unless the changes are made directly in the
  Arcade repository." Flag the edit and point to `dotnet/arcade`.
- `global.json`, `NuGet.config`, `package.json`, and lock files should not change
  unless that is the stated purpose of the pull request.
- Submodule bumps under `src/submodules/**` are normally intentional
  infrastructure changes. Do not treat them as accidental.

## 4. Generated project lists

Two project properties have a generated list that must be regenerated with
`eng/scripts/GenerateProjectList.ps1`. If the diff sets either property, open the
generated file and confirm the assembly is listed:

- `<IsAspNetCoreApp>true</IsAspNetCoreApp>` → `eng/SharedFramework.Local.props`
  (`docs/SharedFramework.md`). Adding an assembly to the shared framework is a
  significant commitment: no third-party dependencies, and no breaking changes in
  patch or minor releases. Worth calling out on its own.
- `<IsTrimmable>true</IsTrimmable>` → `eng/TrimmableProjects.props`
  (`docs/Trimming.md`).

## 5. Diagnostics

If the diff adds a diagnostic ID such as `ASP0000`, open
`docs/list-of-diagnostics.md` and confirm it is registered there and not already
taken by another analyzer. `docs/README.md` describes that file as the list for
"anyone needing to add new codes for diagnostics purposes."

## 6. Tests

- `[QuarantinedTest]` takes a reason documented with a GitHub URL
  (`src/Testing/src/xunit/QuarantinedTestAttribute.cs`). Flag a quarantine with
  no tracking issue link.
- A test quarantined inside a feature or bug-fix pull request deserves an
  explicit callout. It is usually a separate change.
- New behavior with no test is worth one comment. Do not repeat it per file.
- In `src/Components/**` (see `src/Components/AGENTS.md`):
  - E2E tests belong in `src/Components/test/E2ETest`. Prefer extending existing
    test components and assets over adding new ones.
  - Avoid new startup files in `Components.TestServer` unless necessary.
  - Sample scaffolding under `src/Components/Samples` is for local development
    and should not ship in the pull request.

## 7. When to stay quiet

A large share of pull requests here are automated. Keep reviews short on:

- Dependency flow and mirror pull requests — "Update dependencies from build
  ...", "[main] Source code updates from dotnet/dotnet", Dependabot bumps.
- Generated files, including `*.g.cs`, `*.verified.cs` snapshot baselines, and
  minified JavaScript.
- Localization `.resx` churn and submodule pointer updates.

A wrong comment on a bot pull request costs more attention than a missing one.

## Scope

This skill is static analysis over the diff and the repository. It does not
build, run tests, or produce empirical evidence. Deep empirical review is a
separate, developer-initiated workflow (`aspnetcore-pr-review`).
