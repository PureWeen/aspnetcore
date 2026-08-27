import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const evalDirectory = dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(readFileSync(join(evalDirectory, "cases.json"), "utf8"));
const [resultsDirectory, workflowPrefix = "issue-triage-repeat-"] = process.argv.slice(2);

if (!resultsDirectory)
{
  console.error("Usage: node aggregate.mjs <trial-results-directory> [workflow-prefix]");
  process.exit(2);
}

const scoreScript = join(evalDirectory, "score.mjs");
const temporaryDirectory = mkdtempSync(join(tmpdir(), "issue-triage-aggregate-"));
const runs = [];

function checkActual(score, id)
{
  return score.checks.find(check => check.id === id)?.actual ?? null;
}

try
{
  for (const fileName of readdirSync(resolve(resultsDirectory)).filter(file => file.endsWith(".json")).sort())
  {
    const path = join(resolve(resultsDirectory), fileName);
    const trial = JSON.parse(readFileSync(path, "utf8"));
    if (!trial.workflow_name?.startsWith(workflowPrefix))
    {
      continue;
    }

    const caseId = trial.workflow_name.slice(workflowPrefix.length);
    if (!config.cases.some(testCase => testCase.id === caseId))
    {
      throw new Error(`Trial '${fileName}' has unknown case '${caseId}'.`);
    }

    const outputPath = join(temporaryDirectory, `${trial.run_id}.json`);
    writeFileSync(outputPath, JSON.stringify(trial.safe_outputs ?? { items: [] }));
    const scoreResult = spawnSync(
      process.execPath,
      [scoreScript, caseId, outputPath],
      { encoding: "utf8" }
    );
    if (!scoreResult.stdout)
    {
      throw new Error(`Scorer produced no output for run ${trial.run_id}: ${scoreResult.stderr}`);
    }

    const score = JSON.parse(scoreResult.stdout);
    const decision = {
      areas: checkActual(score, "one-top-area"),
      issue_type: checkActual(score, "issue-type"),
      subtypes: checkActual(score, "one-subtype"),
      removed_labels: checkActual(score, "required-label-removal"),
      abstained: checkActual(score, "abstention"),
      duplicate_citations: checkActual(score, "duplicate-citations"),
    };

    runs.push({
      run_id: Number(trial.run_id),
      url: `https://github.com/PureWeen/aspnetcore/actions/runs/${trial.run_id}`,
      timestamp: trial.timestamp,
      case_id: caseId,
      workflow_success: trial.success,
      score: score.score,
      passed: scoreResult.status === 0,
      failed_checks: score.checks
        .filter(check => check.scored && !check.passed)
        .map(check => ({ id: check.id, actual: check.actual, expected: check.expected })),
      output_contract_valid: score.operational.output_contract_valid,
      requested_safe_output_count: score.operational.requested_safe_output_count,
      safe_output_errors: trial.safe_outputs?.errors ?? [],
      decision,
      source_file: basename(path),
    });
  }
}
finally
{
  rmSync(temporaryDirectory, { recursive: true });
}

const cases = config.cases.map(testCase =>
{
  const caseRuns = runs.filter(run => run.case_id === testCase.id);
  const fullDecisionSignatures = [...new Set(caseRuns.map(run => JSON.stringify(run.decision)))];
  const scoredDecisionSignatures = [...new Set(caseRuns.map(run => JSON.stringify({
    areas: testCase.expected.score_area ? run.decision.areas : null,
    issue_type: testCase.expected.score_type ? run.decision.issue_type : null,
    subtypes: testCase.expected.score_subtype ? run.decision.subtypes : null,
    removed_labels: testCase.expected.remove_labels.length > 0 ? run.decision.removed_labels : null,
    abstained: testCase.expected.score_abstention ? run.decision.abstained : null,
    duplicate_citations: testCase.expected.score_duplicates ? run.decision.duplicate_citations : null,
  })))];
  const averageRatio = caseRuns.length === 0
    ? null
    : caseRuns.reduce((total, run) => total + run.score.ratio, 0) / caseRuns.length;

  return {
    case_id: testCase.id,
    historical_outcome: testCase.historical_outcome,
    run_count: caseRuns.length,
    passing_runs: caseRuns.filter(run => run.passed).length,
    pass_rate: caseRuns.length === 0
      ? null
      : caseRuns.filter(run => run.passed).length / caseRuns.length,
    average_score_ratio: averageRatio,
    output_contract_valid_runs: caseRuns.filter(run => run.output_contract_valid).length,
    stable_scored_decision: scoredDecisionSignatures.length <= 1,
    stable_full_decision: fullDecisionSignatures.length <= 1,
    distinct_scored_decisions: scoredDecisionSignatures.map(signature => JSON.parse(signature)),
    distinct_full_decisions: fullDecisionSignatures.map(signature => JSON.parse(signature)),
    run_ids: caseRuns.map(run => run.run_id),
  };
});

const result = {
  schema_version: 1,
  repository: "PureWeen/aspnetcore",
  workflow_prefix: workflowPrefix,
  safe_outputs_staged: true,
  persistence_tested: false,
  summary: {
    expected_cases: config.cases.length,
    observed_cases: cases.filter(testCase => testCase.run_count > 0).length,
    total_runs: runs.length,
    passing_runs: runs.filter(run => run.passed).length,
    output_contract_valid_runs: runs.filter(run => run.output_contract_valid).length,
    stable_scored_cases: cases.filter(testCase => testCase.run_count > 0 && testCase.stable_scored_decision).length,
    stable_full_output_cases: cases.filter(testCase => testCase.run_count > 0 && testCase.stable_full_decision).length,
    complete_cases: cases.filter(testCase => testCase.run_count >= 2).length,
  },
  cases,
  runs: runs.sort((left, right) => left.run_id - right.run_id),
};

console.log(JSON.stringify(result, null, 2));
