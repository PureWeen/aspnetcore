---
name: code-review
description: >-
  Repository-specific review checks for dotnet/aspnetcore pull requests. USE FOR
  reviewing a diff or pull request in this repository, to catch conventions that
  CI does not enforce and that a general-purpose reviewer cannot infer:
  Arcade-owned paths under eng/common, Components and Components.Testing test and
  packaging conventions, and obsoletion diagnostic IDs. Also lists what CI already
  blocks so reviews do not repeat it, and when to stay quiet on dependency-flow
  and generated pull requests. Read-only: analysis and review comments only.
  DO NOT USE FOR building or testing the repository, restating build or CI output,
  or designing the shape of a new public API (use review-public-api).
---

# ASP.NET Core code review

A small set of conventions that **CI does not enforce** and that a
general-purpose reviewer has no way to know. Apply these in addition to normal
review.

Each check is decided by reading files: the diff changes one thing, so open a
file the pull request **did not touch** and confirm it agrees.

## What CI already blocks — do not repeat it

`eng/scripts/CodeCheck.ps1` runs on every pull request
(`.azure/pipelines/ci.yml`) and already fails the build for duplicate project
file names, `package-lock.json` entries from the wrong registry, solution and
`.slnf` inconsistencies, **stale generated files** (it re-runs
`eng/scripts/GenerateProjectList.ps1` and errors on any diff, so
`eng/SharedFramework.Local.props` and `eng/TrimmableProjects.props` cannot drift),
**modifications to an existing `PublicAPI.Shipped.txt`**, `eng/Dependencies.props`
changes without a Dependabot discovery update, and SignalR TypeScript changes
without a `CHANGELOG.md` entry.

The build also treats warnings as errors (`eng/build.sh`) and enables
`Microsoft.CodeAnalysis.PublicApiAnalyzers` on implementation projects
(`eng/targets/CSharp.Common.targets`), so a missing or stale public API entry
(RS0016/RS0017) is already a **build error**.

Commenting on any of that costs the author attention for something they will be
told anyway.

## 1. Automated pull requests — stay quiet

Roughly a fifth of pull requests here are machine-generated. Keep reviews short
or silent on:

- dependency flow and mirror pull requests — "Update dependencies from build
  ...", "[main] Source code updates from dotnet/dotnet", Dependabot bumps
- generated files, including `*.g.cs`, `*.verified.cs` snapshot baselines, and
  minified JavaScript
- localization `.resx` churn and submodule pointer updates under `src/submodules/**`

A wrong comment on an automated pull request costs more than a missing one.

## 2. `eng/common/**` is owned by Arcade

Per `eng/common/AGENTS.md`, edits there "will be overwritten by automation unless
the changes are made directly in the Arcade repository." Nothing fails: the change
builds, merges, and then silently disappears on the next Arcade flow. Point the
author to `dotnet/arcade`.

This applies to `eng/common/` only — the rest of `eng/` is repo-owned and normally
edited. Dependency-flow pull requests update `eng/common/` legitimately; see
section 1.

## 3. Blazor and Components

`src/Components/AGENTS.md` and `src/Components/Testing/AGENTS.md` hold rules no
analyzer encodes:

- E2E tests belong in `src/Components/test/E2ETest`. Prefer extending existing
  test components and assets over adding new ones, and avoid new startup files in
  `Components.TestServer` unless genuinely necessary. Sample scaffolding from
  `src/Components/Samples` should not ship as part of a feature change.
- Under `src/Components/Testing`, the assembly, generators, tasks, and shipped
  MSBuild assets are **product code for external package consumers**, and must stay
  "independent of the ASP.NET Core repository layout, build graph, source-build
  conventions, CI providers, and repository-only projects or properties." Flag
  shipped assets that depend on source-tree bootstrapping, incidental build order,
  or callers setting repository globals. That builds and tests green in-repo and
  fails for the customer.

## 4. Obsoletion diagnostic IDs

Two registries exist and are easy to confuse:

- Analyzer diagnostics (`ASP####`, `BL####`, `MVC####`, `SSG####`) belong in
  `docs/list-of-diagnostics.md`. Check a new ID is registered and not already taken.
- **Obsoletion IDs (`ASPDEPR####`) live in `src/Shared/Obsoletions.cs`, not in that
  doc.** A new `[Obsolete(..., DiagnosticId = "ASPDEPR###")]` should declare its
  constant there and continue the existing numbering. Nothing validates this.

## Scope

Static review of the diff and repository. This skill does not build, run tests, or
produce empirical evidence. Build and CI findings belong to CI; deep empirical
review belongs to the developer-initiated `aspnetcore-pr-review` workflow; new
public API *shape* belongs to `review-public-api` and the `api-approved` process
(`docs/APIReviewProcess.md`).
