---
name: code-review
description: >-
  Repository-specific review check for changes under eng/common in
  dotnet/aspnetcore. Use when reviewing a pull request or diff that changes
  eng/common/**. Identifies edits that belong in dotnet/arcade because this
  directory is synchronized from Arcade and local changes are overwritten.
  Read-only: review analysis and comments only.
---

# ASP.NET Core code review

Apply this check only when the diff changes `eng/common/**`.

## `eng/common/**` changes belong in Arcade

Read `eng/common/AGENTS.md` and `eng/common/README.md` before reviewing a
matching file. Files in this directory come from
[dotnet/arcade](https://github.com/dotnet/arcade), and local edits are
overwritten by automation unless the durable change is made there.

For any change authored directly in this repository, report this
repository-ownership problem:

> This file is synchronized from `dotnet/arcade`, so this local edit will be
> overwritten. Please make the durable change in Arcade and flow it back to
> ASP.NET Core.

Do not report this when the pull request is flowing an upstream update into the
repository. Common examples are titled `[main] Source code updates from
dotnet/dotnet`, `[main] Update dependencies from dotnet/arcade`, or `Update
dependencies from build ...`, and are authored by dependency-flow automation.
An accompanying `eng/Version.Details.xml` update is additional evidence of a
flow. Only report the ownership problem when the pull request context establishes
that the edit was authored directly here; abstain when provenance is unclear.

Keep the finding about ownership and durability. Do not invent a defect in the
changed code merely because the file is under `eng/common/**`.

## Scope

This skill performs static, read-only review. It does not build, run tests, or
modify files.
