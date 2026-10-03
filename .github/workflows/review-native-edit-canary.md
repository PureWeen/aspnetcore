---
name: Fork native-edit replay compatibility canary
description: One bounded fork-only native edit, read, and byte check against AWF v0.28.25.
if: ${{ github.repository == 'PureWeen/aspnetcore' }}
on:
  workflow_dispatch:
  steps:
    - name: Verify the fork-only dispatch before token selection
      run: test "$GITHUB_REPOSITORY" = "PureWeen/aspnetcore"
permissions:
  contents: read
concurrency:
  group: review-native-edit-canary-${{ github.repository }}-${{ github.run_id }}
  cancel-in-progress: false
  job-discriminator: ${{ github.run_id }}
checkout: false
strict: true
timeout-minutes: 15
max-ai-credits: 150
jobs:
  agent:
    timeout-minutes: 15
sandbox:
  agent:
    version: v0.28.25
    model-fallback: false
    images:
      agent: ghcr.io/github/gh-aw-firewall/agent:0.28.25@sha256:25fbbefb92b690d4e6ef34de8df057c0349e6adf2b7486c0cc56954a8e9a3cd4
      apiProxy: ghcr.io/github/gh-aw-firewall/api-proxy:0.28.25@sha256:c3c7082e73ba83052c580097e5a9c9c40a11e6f6b6fa0a4710e6859f83a62854
      squid: ghcr.io/github/gh-aw-firewall/squid:0.28.25@sha256:94cac14372280dbf4a08d021d7b5810a9fd7d73c88802e04a9e05551b1cbcd09
network:
  allowed: [defaults, github, node]
tools:
  bash: [od]
  edit: true
  github: false
safe-outputs:
  noop:
    report-as-issue: false
pre-agent-steps:
  - name: Prepare an empty native-edit canary directory
    run: |
      mkdir -p /tmp/gh-aw/native-edit-canary
      test ! -e /tmp/gh-aw/native-edit-canary/probe.txt
post-steps:
  - name: Independently verify native-edit bytes and runtime configuration
    if: ${{ always() }}
    run: |
      python3 - <<'PY'
      import json
      import os
      import pathlib
      import sys

      root = pathlib.Path("/tmp/gh-aw")
      directory = root / "native-edit-canary"
      probe = directory / "probe.txt"
      expected = b"awf-native-edit-canary-v1\n"
      actual = probe.read_bytes() if probe.is_file() else None
      entries = sorted(item.name for item in directory.iterdir()) if directory.is_dir() else []
      result = {
          "pass": actual == expected and entries == ["probe.txt"],
          "path": str(probe),
          "expected_hex": expected.hex(),
          "actual_hex": actual.hex() if actual is not None else None,
          "expected_bytes": len(expected),
          "actual_bytes": len(actual) if actual is not None else None,
          "scratch_entries": entries,
      }
      root.mkdir(parents=True, exist_ok=True)
      (root / "native-edit-canary-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
      config = pathlib.Path(os.environ["RUNNER_TEMP"]) / "gh-aw" / "awf-config.json"
      if config.is_file():
          runtime = json.loads(config.read_text(encoding="utf-8"))
          selected = {
              "$schema": runtime.get("$schema"),
              "container": runtime.get("container"),
              "modelFallback": runtime.get("apiProxy", {}).get("modelFallback"),
              "maxAiCredits": runtime.get("apiProxy", {}).get("maxAiCredits"),
          }
          (root / "native-edit-canary-runtime.json").write_text(json.dumps(selected, indent=2), encoding="utf-8")
      print(json.dumps(result, indent=2))
      if not result["pass"]:
          sys.exit("CANARY_BYTE_CHECK_FAIL")
      PY
  - name: Upload the distinct native-edit canary proof
    if: ${{ always() }}
    uses: actions/upload-artifact@v7
    with:
      name: review-native-edit-canary-proof
      if-no-files-found: error
      path: |
        /tmp/gh-aw/native-edit-canary/probe.txt
        /tmp/gh-aw/native-edit-canary-result.json
        /tmp/gh-aw/native-edit-canary-runtime.json
imports:
  - uses: shared/pat_pool.md
    with:
      environment: copilot-pat-pool
environment: copilot-pat-pool
model: gpt-5.6-sol
engine:
  id: copilot
  version: "1.0.80"
  env:
    COPILOT_GITHUB_TOKEN: ${{ case(needs.pat_pool.outputs.pat_number == '0', secrets.COPILOT_PAT_0, needs.pat_pool.outputs.pat_number == '1', secrets.COPILOT_PAT_1, needs.pat_pool.outputs.pat_number == '2', secrets.COPILOT_PAT_2, needs.pat_pool.outputs.pat_number == '3', secrets.COPILOT_PAT_3, needs.pat_pool.outputs.pat_number == '4', secrets.COPILOT_PAT_4, needs.pat_pool.outputs.pat_number == '5', secrets.COPILOT_PAT_5, needs.pat_pool.outputs.pat_number == '6', secrets.COPILOT_PAT_6, needs.pat_pool.outputs.pat_number == '7', secrets.COPILOT_PAT_7, needs.pat_pool.outputs.pat_number == '8', secrets.COPILOT_PAT_8, needs.pat_pool.outputs.pat_number == '9', secrets.COPILOT_PAT_9, 'NO COPILOT PAT AVAILABLE') }}
---

# Native-edit Responses replay canary

Perform only this compatibility check. Do not review a pull request, read target
repository source, build or test target code, use workers, access GitHub, install
anything, or create public output. Never use an Anthropic model or model fallback.

Use three separate native tool turns in this exact order. Do not batch them into
one turn: the next model request must replay the successful custom edit.

1. Your first native tool call must be `apply_patch`. Add exactly one text file,
   `/tmp/gh-aw/native-edit-canary/probe.txt`, with this patch:

   ```text
   *** Begin Patch
   *** Add File: /tmp/gh-aw/native-edit-canary/probe.txt
   +awf-native-edit-canary-v1
   *** End Patch
   ```

   The file must contain exactly the ASCII bytes `awf-native-edit-canary-v1`
   followed by one LF, totaling 26 bytes. Do not use shell commands, another write
   tool, or a worker to create it. Do not edit any other file.
2. After the successful edit result, use the native `view` tool to read the exact
   absolute file path. Do this on a subsequent native tool turn. Confirm its
   content is `awf-native-edit-canary-v1`.
3. After the successful native read, invoke the shell tool with exactly this bare
   command, on another separate turn:

   ```text
   od -An -tx1 /tmp/gh-aw/native-edit-canary/probe.txt
   ```

   No timing wrapper, assignment, pipe, redirection, `cd`, or compound command is
   needed. The bytes must be exactly:

   ```text
   61 77 66 2d 6e 61 74 69 76 65 2d 65 64 69 74 2d 63 61 6e 61 72 79 2d 76 31 0a
   ```

Only after all three successful tool results and the exact byte match, call
`noop` with `NATIVE_EDIT_REPLAY_PASS; byte_count=26; native edit, subsequent native
read, and subsequent byte-check tool turn all completed`, then give the same
terminal result. This noop must not publish an issue or comment.

If a required native tool is unavailable, a tool fails, the bytes differ, or a
Responses request fails, do not substitute a shell write or report success.
Report `NATIVE_EDIT_REPLAY_FAIL` with the exact tool/error or observed mismatch.
