import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const evalDirectory = dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(readFileSync(join(evalDirectory, "cases.json"), "utf8"));
const [caseId, outputPath, safeOutputItemsPath] = process.argv.slice(2);

if (!caseId || !outputPath)
{
  console.error("Usage: node score.mjs <case-id> <agent-output.json> [safe-output-items.jsonl]");
  process.exit(2);
}

const testCase = config.cases.find(candidate => candidate.id === caseId);
if (!testCase)
{
  console.error(`Unknown case '${caseId}'.`);
  process.exit(2);
}

const snapshot = JSON.parse(readFileSync(join(evalDirectory, "snapshots", `${caseId}.json`), "utf8"));
const agentOutput = JSON.parse(readFileSync(resolve(outputPath), "utf8"));
const items = Array.isArray(agentOutput) ? agentOutput : agentOutput.items ?? [];
const checks = [];

function addCheck(id, scored, passed, actual, expected)
{
  checks.push({ id, scored, passed: scored ? passed : null, actual, expected });
}

function normalize(value)
{
  return typeof value === "string" ? value.toLowerCase() : value;
}

function labelNames(item)
{
  return (item?.labels ?? []).map(label => normalize(typeof label === "string" ? label : label.name)).filter(Boolean);
}

const addLabelItems = items.filter(item => item.type === "add_labels");
const removeLabelItems = items.filter(item => item.type === "remove_labels");
const typeItems = items.filter(item => item.type === "set_issue_type");
const commentItems = items.filter(item => item.type === "add_comment");
const noopItems = items.filter(item => item.type === "noop");
const requestedLabels = addLabelItems.flatMap(labelNames);
const removedLabels = removeLabelItems.flatMap(labelNames);
const initialLabels = snapshot.issue.initial_labels.map(normalize);
const effectiveLabels = [...new Set([...initialLabels.filter(label => !removedLabels.includes(label)), ...requestedLabels])];
const effectiveAreas = effectiveLabels.filter(label => config.contract.area_labels.includes(label));
const effectiveSubtypes = effectiveLabels.filter(label => config.contract.subtype_labels.includes(label));
const requestedType = typeItems.at(-1)?.issue_type ?? typeItems.at(-1)?.type_name ?? null;
const effectiveType = requestedType ?? snapshot.issue.initial_type;
const actualAbstention = noopItems.length > 0 && commentItems.length === 0;
const expected = testCase.expected;
const expectedIssueNumber = snapshot.issue.number;
const targetChecks = [
  ...addLabelItems.map(item => ({ type: item.type, actual: Number(item.item_number) })),
  ...removeLabelItems.map(item => ({ type: item.type, actual: Number(item.item_number) })),
  ...typeItems.map(item => ({ type: item.type, actual: Number(item.issue_number) })),
  ...commentItems.map(item => ({ type: item.type, actual: Number(item.item_number) })),
];

addCheck(
  "one-top-area",
  expected.score_area,
  effectiveAreas.length === 1 && expected.accepted_areas.map(normalize).includes(effectiveAreas[0]),
  effectiveAreas,
  expected.accepted_areas.map(normalize)
);
addCheck(
  "issue-type",
  expected.score_type,
  normalize(effectiveType) === normalize(expected.issue_type),
  effectiveType,
  expected.issue_type
);
addCheck(
  "one-subtype",
  expected.score_subtype,
  effectiveSubtypes.length === 1 && effectiveSubtypes[0] === normalize(expected.subtype),
  effectiveSubtypes,
  expected.subtype
);
addCheck(
  "required-label-removal",
  expected.remove_labels.length > 0,
  expected.remove_labels.map(normalize).every(label => removedLabels.includes(label)),
  removedLabels,
  expected.remove_labels.map(normalize)
);
addCheck(
  "abstention",
  expected.score_abstention,
  actualAbstention === expected.abstain,
  actualAbstention,
  expected.abstain
);

const duplicateCitations = commentItems
  .flatMap(item => [...(item.body ?? "").matchAll(/(?:^|[^\w])#(\d+)/g)])
  .map(match => Number(match[1]));
addCheck(
  "duplicate-citations",
  expected.score_duplicates,
  duplicateCitations.length > 0 && duplicateCitations.every(number => expected.allowed_duplicate_issue_numbers.includes(number)),
  duplicateCitations,
  expected.allowed_duplicate_issue_numbers
);

const allowedLabels = new Set([
  ...config.contract.area_labels,
  ...config.contract.subtype_labels,
]);
addCheck(
  "allowed-labels-only",
  true,
  requestedLabels.every(label => allowedLabels.has(label)),
  requestedLabels,
  [...allowedLabels]
);
addCheck("single-type-request", true, typeItems.length <= 1, typeItems.length, "0 or 1");
addCheck("comment-xor-noop", true, !(commentItems.length > 0 && noopItems.length > 0), { comments: commentItems.length, noops: noopItems.length }, "not both");
addCheck(
  "exact-targets",
  true,
  targetChecks.every(target => target.actual === expectedIssueNumber),
  targetChecks,
  `all mutation intents target issue ${expectedIssueNumber}`
);

let persisted = null;
if (safeOutputItemsPath)
{
  const records = readFileSync(resolve(safeOutputItemsPath), "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .map(line => JSON.parse(line));
  const labelRecords = records.filter(record => record.type === "add_labels" && record.after_state?.labels);
  const persistedLabels = labelRecords.flatMap(record => record.after_state.labels.map(normalize));
  persisted = {
    requested: requestedLabels,
    after_state: [...new Set(persistedLabels)],
    passed: requestedLabels.every(label => persistedLabels.includes(label)),
  };
}

const scoredChecks = checks.filter(check => check.scored);
const passedChecks = scoredChecks.filter(check => check.passed);
const result = {
  schema_version: 1,
  case_id: caseId,
  historical_outcome: testCase.historical_outcome,
  score: {
    passed: passedChecks.length,
    total: scoredChecks.length,
    ratio: scoredChecks.length === 0 ? null : passedChecks.length / scoredChecks.length,
  },
  checks,
  operational: {
    agent_output_read: true,
    requested_safe_output_count: items.length,
    output_contract_valid: checks.filter(check => ["allowed-labels-only", "single-type-request", "comment-xor-noop", "exact-targets"].includes(check.id)).every(check => check.passed),
    persisted_after_state: persisted,
  },
};

console.log(JSON.stringify(result, null, 2));
process.exit(passedChecks.length === scoredChecks.length ? 0 : 1);
