import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const scoreScript = new URL("score.mjs", import.meta.url);

function score(caseId, items)
{
  const directory = mkdtempSync(join(tmpdir(), "issue-triage-score-"));
  const outputPath = join(directory, "agent-output.json");
  writeFileSync(outputPath, JSON.stringify({ items }));

  const result = spawnSync(
    process.execPath,
    [scoreScript.pathname, caseId, outputPath],
    { encoding: "utf8" }
  );
  rmSync(directory, { recursive: true });

  return {
    exitCode: result.status,
    output: JSON.parse(result.stdout),
  };
}

test("accepts a correctly targeted classification", () =>
{
  const result = score("67979-missing-data", [
    {
      type: "add_labels",
      item_number: 67979,
      labels: [{ name: "area-blazor" }],
    },
    {
      type: "set_issue_type",
      issue_number: 67979,
      issue_type: "Bug",
    },
    {
      type: "add_comment",
      item_number: 67979,
      body: "### Triage Summary",
    },
  ]);

  assert.equal(result.exitCode, 0);
  assert.equal(result.output.score.ratio, 1);
  assert.equal(result.output.operational.output_contract_valid, true);
});

test("rejects a missing workflow-dispatch target", () =>
{
  const result = score("67979-missing-data", [
    {
      type: "add_labels",
      item_number: 67979,
      labels: [{ name: "area-blazor" }],
    },
    {
      type: "set_issue_type",
      issue_type: "Bug",
    },
  ]);

  assert.equal(result.exitCode, 1);
  assert.equal(result.output.checks.find(check => check.id === "exact-targets").passed, false);
  assert.equal(result.output.operational.output_contract_valid, false);
});

test("rejects an incorrect area", () =>
{
  const result = score("67614-startup-failure", [
    {
      type: "add_labels",
      item_number: 67614,
      labels: [{ name: "area-blazor" }],
    },
    {
      type: "set_issue_type",
      issue_number: 67614,
      issue_type: "Bug",
    },
  ]);

  assert.equal(result.exitCode, 1);
  assert.equal(result.output.checks.find(check => check.id === "one-top-area").passed, false);
});

test("accepts an idempotent no-op using initial state", () =>
{
  const result = score("68331-clean-control", [
    {
      type: "noop",
      message: "No action needed: issue is already classified.",
    },
  ]);

  assert.equal(result.exitCode, 0);
  assert.equal(result.output.score.ratio, 1);
  assert.equal(result.output.checks.find(check => check.id === "abstention").passed, true);
});
