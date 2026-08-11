---
name: code-review
description: >-
  Repository-specific review checks for dotnet/aspnetcore pull requests. USE FOR
  reviewing a diff or pull request in this repository, to catch ASP.NET Core
  policy and cross-file conventions that neither a general-purpose reviewer nor
  the build can detect: servicing and release-branch API freezes, Arcade-owned
  paths, generated shared-framework and trimming project lists, diagnostic ID
  registration, public API baseline policy, quarantined tests, and Components
  test placement. Also covers when to stay quiet on dependency-flow, mirror, and
  generated-file pull requests. Read-only: analysis and review comments only.
  DO NOT USE FOR building or testing the repository, restating analyzer output,
  or designing the shape of a new public API (use review-public-api).
---

# ASP.NET Core code review

Repository policy and cross-file conventions that a general-purpose reviewer
cannot infer. Apply these in addition to normal review.

## How to use this skill

Every check here is decided by **reading files**, not by building or running
anything. A review cannot compile this repository in the time it has, so nothing
below asks for compilation, test execution, or red/green proof.

Each check has the same shape: the diff changes one thing, so open a specific
file the pull request **did not touch** and confirm it agrees. That cross-file
comparison is where this skill earns its place — the file that proves the
problem is usually not in the diff.

Three limits to respect:

- **Do not restate what the build already reports.** This repository builds with
  `warnaserror` (`eng/common/build.sh`) and enables
  `Microsoft.CodeAnalysis.PublicApiAnalyzers` on shipping `src` projects
  (`eng/targets/CSharp.Common.targets`). A missing or stale `PublicAPI.*.txt`
  entry is already a build error (RS0016/RS0017), and `.editorconfig` plus the
  analyzers cover style. Commenting on those wastes the author's attention.
- Comment only when a file you actually read supports the claim. Cite it by path.
- If a concern depends on runtime behavior — concurrency, lifecycle, transport,
  browser — say it needs verification rather than asserting it. Do not imply you
  ran anything.

The checks below are ordered by how much they add beyond the build. The first
four are invisible to every analyzer in this repository.

## 1. Servicing and release branches

Check the base branch first. If it is `release/*`, apply `docs/Servicing.md`:

- Patches **cannot** add, remove, or change public API. Apps must stay
  binary-compatible across every patch of a major.minor. An API change on a
  `release/*` pull request is a finding even when the code is correct and the
  baseline files are updated consistently — the build will not object, because
  the baselines agree with the code.
- Servicing pull requests need the servicing template filled in and are gated on
  Shiproom review. An empty template is worth one comment.

## 2. Paths owned by other repositories or by automation

- **`eng/common/**` is owned by Arcade.** Per `eng/common/AGENTS.md`, edits there
  "will be overwritten by automation unless the changes are made directly in the
  Arcade repository." The change will build and pass, then silently disappear on
  the next Arcade flow. Flag it and point to `dotnet/arcade`.
- `global.json`, `NuGet.config`, `package.json`, and lock files should not change
  unless that is the stated purpose of the pull request.
- Submodule bumps under `src/submodules/**` are normally intentional. Do not
  treat them as accidental.

## 3. Generated project lists

Two project properties have a generated list that must be regenerated with
`eng/scripts/GenerateProjectList.ps1`. If the diff sets either property, open the
generated file and confirm the assembly is listed. Nothing fails the build when
they disagree:

- `<IsAspNetCoreApp>true</IsAspNetCoreApp>` → `eng/SharedFramework.Local.props`
  (`docs/SharedFramework.md`). Adding an assembly to the shared framework is also
  a significant commitment — no third-party dependencies, and no breaking changes
  in patch or minor releases — and is worth calling out on its own.
- `<IsTrimmable>true</IsTrimmable>` → `eng/TrimmableProjects.props`
  (`docs/Trimming.md`).

## 4. Diagnostic IDs

If the diff adds a diagnostic ID such as `ASP0000`, open
`docs/list-of-diagnostics.md` and confirm it is registered there and not already
taken. `docs/README.md` describes that file as the list for "anyone needing to
add new codes for diagnostics purposes." A duplicate or unregistered ID compiles
cleanly.

## 5. Public API policy

The analyzers already enforce that `PublicAPI.*.txt` matches the code. What they
do not enforce is policy (`docs/APIBaselines.md`):

- **`PublicAPI.Shipped.txt` changes need a stated reason.** It "should only be
  modified after a major release by the build team and should never be modified
  otherwise." Legitimate exceptions exist — marking a released version as
  shipped, baseline resets, merge-conflict repair — so ask why rather than
  asserting the change is wrong, and do not raise it on a pull request whose
  stated purpose is a baseline update.
- A `*REMOVED*` entry means a **binary-breaking change**. The baseline files can
  be perfectly consistent and the change still be wrong for the target branch or
  release. Say what breaks rather than that a line is missing.
- New shipping `src` projects need both baseline files, copied from
  `eng/PublicAPI.empty.txt` — or `<AddPublicApiAnalyzers>false</AddPublicApiAnalyzers>`
  for non-shipping and test-only projects.
- Whether a *new* API is well-shaped is a separate question. Defer to the
  `review-public-api` skill and the `api-ready-for-review` process
  (`docs/APIReviewProcess.md`) instead of redesigning it inline.

## 6. Tests

- `[QuarantinedTest]` takes a reason documented with a GitHub URL
  (`src/Testing/src/xunit/QuarantinedTestAttribute.cs`). Flag a quarantine with
  no tracking issue link.
- A test quarantined inside a feature or bug-fix pull request deserves an
  explicit callout. It is usually a separate change.
- In `src/Components/**` (see `src/Components/AGENTS.md`), E2E tests belong in
  `src/Components/test/E2ETest`; prefer extending existing test components and
  assets over adding new ones, avoid new startup files in
  `Components.TestServer` unless necessary, and do not ship sample scaffolding
  from `src/Components/Samples`.

## 7. When to stay quiet

A large share of pull requests here are automated. Keep reviews short on:

- Dependency flow and mirror pull requests — "Update dependencies from build
  ...", "[main] Source code updates from dotnet/dotnet", Dependabot bumps.
- Generated files, including `*.g.cs`, `*.verified.cs` snapshot baselines, and
  minified JavaScript.
- Localization `.resx` churn and submodule pointer updates.

A wrong comment on an automated pull request costs more attention than a missing
one.

## Scope

This skill is static analysis over the diff and the repository. It does not
build, run tests, or produce empirical evidence. Deep empirical review is a
separate, developer-initiated workflow (`aspnetcore-pr-review`).
