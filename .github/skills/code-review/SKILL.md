---
name: code-review
description: >-
  Repository-specific review checks for dotnet/aspnetcore pull requests. USE FOR
  reviewing a diff or pull request in this repository, to catch conventions that
  CI does not enforce and that a general-purpose reviewer cannot infer:
  Arcade-owned paths under eng/common, Components and Components.Testing test and
  packaging conventions, and obsoletion diagnostic IDs. Also lists what CI already
  checks so reviews do not repeat it, and when to stay quiet on dependency-flow
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

## What CI already checks — do not repeat it

`eng/scripts/CodeCheck.ps1` runs on every pull request
(`.azure/pipelines/ci.yml`) and covers a range of repository-consistency rules.
Two matter most because reviewers duplicate them:

- It re-runs `eng/scripts/GenerateProjectList.ps1` and errors if the result
  differs, so the generated project lists — including
  `eng/SharedFramework.Local.props` and `eng/TrimmableProjects.props` — cannot
  silently drift from the projects.
- It fails on **modifications to an existing `PublicAPI.Shipped.txt`**. Note it
  only inspects files the pull request modified, so a newly *added* baseline file
  is not covered.

The build also treats warnings as errors (`eng/build.sh`) and enables
`Microsoft.CodeAnalysis.PublicApiAnalyzers` on implementation projects that have
not opted out (`eng/targets/CSharp.Common.targets`), so a missing or stale public
API entry (RS0016/RS0017) is normally already a **build error**.

These are reported by the build, usually well after this review runs. Raising them
here costs the author attention for something they will be told anyway — and if
you believe one slipped through, say what CI misses rather than restating the rule.

## 1. Automated pull requests — stay quiet

Roughly a fifth of pull requests here are machine-generated: dependency flow and
mirror updates ("Update dependencies from build ...", "[main] Source code updates
from dotnet/dotnet"), Dependabot bumps, and similar. On those, do not comment on
the churn itself — version and hash bumps, generated files, localization `.resx`
updates, submodule pointer moves under `src/submodules/**`, or `eng/common/`
updates (see section 2).

**This is not blanket silence.** A mirror pull request can carry a hundred real
`.cs` files, and those deserve normal review. Judge the *content* of a change, not
the identity of its author.

The same restraint applies to genuinely generated output anywhere (`*.g.cs`,
minified JavaScript). It does **not** apply to snapshot baselines such as
`*.verified.cs` in a human-authored pull request: those change because someone
accepted new behavior, so the diff is a signal worth reading.

A wrong comment on routine automated churn costs more than a missing one.

## 2. `eng/common/**` is owned by Arcade

Per `eng/common/AGENTS.md`, edits there "will be overwritten by automation unless
the changes are made directly in the Arcade repository." Typically nothing fails:
the change builds, merges, and then silently disappears on the next Arcade flow.
Point the author to `dotnet/arcade`.

This applies to `eng/common/` only — the rest of `eng/` is repo-owned and normally
edited, apart from generated or dependency-flow files such as
`eng/Version.Details.props`. Dependency-flow pull requests update `eng/common/`
legitimately; see section 1.

## 3. Blazor and Components

`src/Components/AGENTS.md` and `src/Components/Testing/AGENTS.md` hold rules no
analyzer encodes:

- E2E tests belong in `src/Components/test/E2ETest`. Prefer extending existing
  test components and assets over adding new ones, and avoid new startup files in
  `Components.TestServer` unless genuinely necessary. The projects under
  `src/Components/Samples` are canonical maintained apps, and changing them is
  normal — flag only leftover development scaffolding, which looks like scratch
  test pages, `TODO: remove` markers, or localhost-only configuration left behind
  by a feature branch.
- Under `src/Components/Testing`, the assembly, generators, tasks, and shipped
  MSBuild assets are **product code for external package consumers**, and must stay
  "independent of the ASP.NET Core repository layout, build graph, source-build
  conventions, CI providers, and repository-only projects or properties." The
  concrete signal is a shipped asset reaching for something only the repository
  provides — `$(RepoRoot)`, `$(RepositoryRoot)`, artifacts paths, or targets and
  properties defined in root `eng/` files. That can build and test green in-repo
  and still fail for the customer.

## 4. Obsoletion diagnostic IDs

Two registries exist and are easy to confuse:

- Analyzer diagnostics (`ASP`, `BL`, `MVC`, `RDG`, `SSG`, ... prefixes) belong in
  `docs/list-of-diagnostics.md`. Check a new ID is registered there, follows the
  numbering its family already uses, and is not already taken.
- **Obsoletion IDs (`ASPDEPR` + three digits) are not in that doc** — they are
  tracked in `src/Shared/Obsoletions.cs`. A new
  `[Obsolete(..., DiagnosticId = "ASPDEPR###")]` should take the next number above
  the current maximum there, and the newest entries also declare the ID as a
  constant. The sequence already has gaps (001 and 007 are absent); those are
  pre-existing, so do not raise them. Nothing validates any of this.

## Scope

Static review of the diff and repository. This skill does not build, run tests, or
produce empirical evidence. Build and CI findings belong to CI; deep empirical
review belongs to the developer-initiated `aspnetcore-pr-review` workflow; new
public API *shape* belongs to `review-public-api` and the `api-approved` process
(`docs/APIReviewProcess.md`).
