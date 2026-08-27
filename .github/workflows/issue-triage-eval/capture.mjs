import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const evalDirectory = dirname(fileURLToPath(import.meta.url));
const configPath = join(evalDirectory, "cases.json");
const snapshotsDirectory = join(evalDirectory, "snapshots");
const config = JSON.parse(readFileSync(configPath, "utf8"));

function ghApi(path, paginate = false)
{
  const args = ["api"];
  if (paginate)
  {
    args.push("--paginate", "--slurp");
  }
  args.push(path);

  const result = JSON.parse(execFileSync("gh", args, { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 }));
  return paginate ? result.flat() : result;
}

function normalizeLabelName(label)
{
  return typeof label === "string" ? label : label?.name;
}

function setLabel(labels, name)
{
  const existing = [...labels].find(label => label.toLowerCase() === name.toLowerCase());
  if (existing)
  {
    labels.delete(existing);
  }
  labels.add(name);
}

function removeLabel(labels, name)
{
  const existing = [...labels].find(label => label.toLowerCase() === name.toLowerCase());
  if (existing)
  {
    labels.delete(existing);
  }
}

function reconstructState(timeline, cutoff)
{
  const labels = new Set();
  let issueType = null;

  for (const event of timeline
    .filter(event => event.created_at && event.created_at <= cutoff)
    .sort((left, right) => left.created_at.localeCompare(right.created_at)))
  {
    if (event.event === "labeled" && event.label?.name)
    {
      setLabel(labels, event.label.name);
    }
    else if (event.event === "unlabeled" && event.label?.name)
    {
      removeLabel(labels, event.label.name);
    }
    else if ((event.event === "issue_type_added" || event.event === "issue_type_changed") && event.issue_type?.name)
    {
      issueType = event.issue_type.name;
    }
    else if (event.event === "issue_type_removed")
    {
      issueType = null;
    }
  }

  return {
    labels: [...labels].sort((left, right) => left.localeCompare(right)),
    issue_type: issueType,
  };
}

mkdirSync(snapshotsDirectory, { recursive: true });

for (const testCase of config.cases)
{
  const snapshotCutoff = testCase.snapshot_cutoff ?? config.snapshot_cutoff;
  const issue = ghApi(`repos/${config.repository}/issues/${testCase.issue_number}`);
  const timeline = ghApi(`repos/${config.repository}/issues/${testCase.issue_number}/timeline?per_page=100`, true);
  const edits = timeline.filter(event => event.event === "edited");

  if (edits.length > 0)
  {
    throw new Error(`Issue #${testCase.issue_number} has edited events, so its original title/body cannot be frozen from the current API response.`);
  }

  if (issue.created_at > snapshotCutoff)
  {
    throw new Error(`Issue #${testCase.issue_number} was created after the configured snapshot cutoff.`);
  }

  const state = reconstructState(timeline, snapshotCutoff);
  const body = issue.body ?? "";
  const snapshot = {
    schema_version: config.schema_version,
    case_id: testCase.id,
    source: {
      repository: config.repository,
      issue_number: issue.number,
      issue_url: issue.html_url,
      created_at: issue.created_at,
      snapshot_cutoff: snapshotCutoff,
      frozen_at: config.frozen_at,
      title_and_body_edited: false,
      body_sha256: createHash("sha256").update(body).digest("hex"),
    },
    issue: {
      number: issue.number,
      title: issue.title,
      body,
      initial_labels: state.labels,
      initial_type: state.issue_type,
    },
  };

  writeFileSync(join(snapshotsDirectory, `${testCase.id}.json`), `${JSON.stringify(snapshot, null, 2)}\n`);
}

console.log(`Captured ${config.cases.length} public issue snapshots in ${snapshotsDirectory}`);
