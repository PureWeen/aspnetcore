import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const [caseId, outputPath] = process.argv.slice(2);
if (!caseId || !outputPath)
{
  console.error("Usage: node materialize-trial.mjs <case-id> <output-workflow.md>");
  process.exit(2);
}

const evalDirectory = new URL(".", import.meta.url);
const config = JSON.parse(readFileSync(new URL("cases.json", evalDirectory), "utf8"));
const testCase = config.cases.find(candidate => candidate.id === caseId);
if (!testCase)
{
  console.error(`Unknown case '${caseId}'.`);
  process.exit(2);
}

const snapshot = readFileSync(new URL(`snapshots/${caseId}.json`, evalDirectory), "utf8").trim();
const workflowPath = new URL("../issue-triage-agent.md", evalDirectory);
let workflow = readFileSync(workflowPath, "utf8");

workflow = workflow.replace(
  /(\n      eval_case:\n(?:.*\n)*?        default: )none(\n        options:)/,
  `$1${caseId}$2`
);
workflow = workflow.replace(/\nsteps:\n[\s\S]*?\nsafe-outputs:\n/, "\nsafe-outputs:\n");
workflow = workflow.replace(
  /  staged: \$\{\{ github\.event_name == 'workflow_dispatch' && github\.event\.inputs\.eval_case != 'none' \}\}/,
  "  staged: true"
);

const contextStart = "## Issue to Triage";
const contextEnd = "## Security Concerns Are Out of Scope";
const startIndex = workflow.indexOf(contextStart);
const endIndex = workflow.indexOf(contextEnd);
if (startIndex < 0 || endIndex < 0)
{
  throw new Error("Could not locate the frozen evaluation context block.");
}

const inlineContext = `## Issue to Triage

This is a **frozen replay evaluation**. It is staged and read-only: request the
same safe outputs you would request in production, but do not change your
classification behavior because the writes will be previewed rather than
applied.

Use this frozen point-in-time issue snapshot as the complete source of truth:

\`\`\`json
${snapshot}
\`\`\`

Do not fetch the current live issue, comments, labels, or type. Do not read
\`.github/workflows/issue-triage-eval/cases.json\` or any scoring output.
Looking at expected results invalidates the evaluation.

`;
workflow = `${workflow.slice(0, startIndex)}${inlineContext}${workflow.slice(endIndex)}`;

writeFileSync(resolve(outputPath), workflow);
console.log(`Materialized ${caseId} to ${resolve(outputPath)}`);
