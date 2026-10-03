import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const repositoryRoot = path.resolve(process.env.REVIEW_PUBLICATION_TEST_ROOT ?? path.join(import.meta.dirname, '../../..'));
const workflowSource = path.join(repositoryRoot, '.github/workflows/pull-request-review.md');
const workflowLock = path.join(repositoryRoot, '.github/workflows/pull-request-review.lock.yml');
const stepName = 'Reject incomplete or partial publication sets';

function extractScript(filename) {
  const lines = fs.readFileSync(filename, 'utf8').split(/\r?\n/);
  const step = lines.findIndex(line => line.trim() === `- name: ${stepName}`);
  assert.notEqual(step, -1, `${filename} does not contain the publication preflight step.`);
  const marker = lines.findIndex((line, index) => index > step && line.trim() === 'script: |');
  assert.notEqual(marker, -1, `${filename} does not contain the publication preflight script.`);
  const markerIndent = lines[marker].search(/\S/);
  const firstBodyLine = lines.findIndex((line, index) =>
    index > marker && line.trim().length > 0 && line.search(/\S/) > markerIndent);
  assert.notEqual(firstBodyLine, -1, `${filename} has an empty publication preflight script.`);
  const bodyIndent = lines[firstBodyLine].search(/\S/);
  const body = [];
  for (let index = marker + 1; index < lines.length; index++) {
    const line = lines[index];
    if (line.trim().length > 0 && line.search(/\S/) <= markerIndent) {
      break;
    }
    body.push(line.length >= bodyIndent ? line.slice(bodyIndent) : '');
  }
  return body.join('\n').trimEnd();
}

const identity = { schemaVersion: 1, headSha: 'a'.repeat(40), mergeBaseSha: 'b'.repeat(40),
  baseTipSha: 'c'.repeat(40), supportingEvidenceOnly: true };
const available = { ...identity, available: true, classification: 'red-green', reason: 'Paired changed-test results.' };
const unavailable = { ...identity, available: false, classification: 'infra-failure', reason: 'restore failed' };
const unavailableBody = 'Review completed source-only with no new findings; execution evidence unavailable (infra-failure): restore failed';

function execute(script, input, execution = available, headSha = identity.headSha) {
  const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'review-publication-preflight-'));
  try {
    const artifact = path.join(temporaryRoot, 'review-publication-gate');
    fs.mkdirSync(artifact);
    fs.writeFileSync(path.join(artifact, 'agent_output.json'),
      input?.rawJson ?? JSON.stringify(input));
    if (!execution?.missing) {
      fs.writeFileSync(path.join(artifact, 'execution.json'), execution?.rawJson ?? JSON.stringify(execution));
    }
    const failures = [];
    const core = { setFailed: message => failures.push(message) };
    let error;
    try {
      Function('require', 'process', 'core', script)(
        moduleName => moduleName === 'fs' ? fs : moduleName === 'path' ? path : undefined,
        { env: { RUNNER_TEMP: temporaryRoot, REVIEW_HEAD: headSha } },
        core);
    } catch (caught) {
      error = caught;
    }
    return { failures, error };
  } finally {
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

const comment = () => ({ type: 'create_pull_request_review_comment' });
const review = () => ({ type: 'submit_pull_request_review', body: 'Execution: red-green\nPaired changed-test results.' });
const rawJson = value => ({ rawJson: value });
const stopped = (type, reason = 'The review could not complete.', status = 'INCOMPLETE') => ({
  items: [
    { type, reason },
    {
      type: 'add_comment',
      body: `Review not published (${status}): ${reason}\n\nNo partial findings were published.`,
    },
  ],
  errors: [],
});
const findings = count => ({
  items: [...Array.from({ length: count }, comment), review()],
  errors: [],
});

const cases = [
  ['one finding', findings(1), true],
  ['five findings', findings(5), true],
  ['clean noop without errors property', { items: [{ type: 'noop' }] }, true],
  ['clean noop with empty errors', { items: [{ type: 'noop' }], errors: [] }, true],
  ['report incomplete', stopped('report_incomplete', 'The review could not complete.', 'BLOCKED'), true],
  ['missing data', stopped('missing_data'), true],
  ['missing tool', stopped('missing_tool'), true],
  ['empty items without errors property', { items: [] }, false],
  ['empty items with empty errors', { items: [], errors: [] }, false],
  ['collector errors with otherwise valid item',
    { items: [{ type: 'noop' }], errors: ["Line 2: Unexpected output type 'unknown'"] }, false],
  ['collector errors with no retained items',
    { items: [], errors: ["Line 1: Unexpected output type 'unknown'"] }, false],
  ['unknown only', { items: [{ type: 'unknown' }], errors: [] }, false],
  ['unknown extra', { items: [{ type: 'noop' }, { type: 'unknown' }], errors: [] }, false],
  ['duplicate noop', { items: [{ type: 'noop' }, { type: 'noop' }], errors: [] }, false],
  ['duplicate reviews', { items: [comment(), review(), review()], errors: [] }, false],
  ['mixed outputs', { items: [{ type: 'noop' }, comment(), review()], errors: [] }, false],
  ['comment only', { items: [comment()], errors: [] }, false],
  ['review only', { items: [review()], errors: [] }, false],
  ['too many findings', findings(6), false],
  ['signal only', { items: [{ type: 'report_incomplete', reason: 'Reason' }], errors: [] }, false],
  ['status only', {
    items: [{
      type: 'add_comment',
      body: 'Review not published (BLOCKED): Reason\n\nNo partial findings were published.',
    }],
    errors: [],
  }, false],
  ['duplicate signal', {
    items: [
      { type: 'report_incomplete', reason: 'Reason' },
      { type: 'missing_data', reason: 'Reason' },
      {
        type: 'add_comment',
        body: 'Review not published (BLOCKED): Reason\n\nNo partial findings were published.',
      },
    ],
    errors: [],
  }, false],
  ['duplicate status', {
    items: [
      { type: 'report_incomplete', reason: 'Reason' },
      {
        type: 'add_comment',
        body: 'Review not published (BLOCKED): Reason\n\nNo partial findings were published.',
      },
      {
        type: 'add_comment',
        body: 'Review not published (BLOCKED): Reason\n\nNo partial findings were published.',
      },
    ],
    errors: [],
  }, false],
  ['reason mismatch', {
    items: [
      { type: 'report_incomplete', reason: 'First' },
      {
        type: 'add_comment',
        body: 'Review not published (BLOCKED): Second\n\nNo partial findings were published.',
      },
    ],
    errors: [],
  }, false],
  ['malformed reason', {
    items: [
      { type: 'report_incomplete', reason: 42 },
      {
        type: 'add_comment',
        body: 'Review not published (BLOCKED): 42\n\nNo partial findings were published.',
      },
    ],
    errors: [],
  }, false],
  ['empty reason', stopped('report_incomplete', ''), false],
  ['long reason', stopped('report_incomplete', 'x'.repeat(241)), false],
  ['multiline reason', stopped('report_incomplete', 'First\nSecond'), false],
  ['status trailing newline', {
    items: [
      { type: 'report_incomplete', reason: 'Reason' },
      {
        type: 'add_comment',
        body: 'Review not published (BLOCKED): Reason\n\nNo partial findings were published.\n',
      },
    ],
    errors: [],
  }, false],
  ['invalid json', rawJson('{'), false],
  ['null root', null, false],
  ['array root', [], false],
  ['string root', 'root', false],
  ['missing items', {}, false],
  ['null items', { items: null }, false],
  ['object items', { items: {} }, false],
  ['null item', { items: [null] }, false],
  ['array item', { items: [[]] }, false],
  ['string item', { items: ['noop'] }, false],
  ['missing item type', { items: [{}] }, false],
  ['null item type', { items: [{ type: null }] }, false],
  ['object item type', { items: [{ type: {} }] }, false],
  ['null errors', { items: [{ type: 'noop' }], errors: null }, false],
  ['object errors', { items: [{ type: 'noop' }], errors: {} }, false],
  ['string errors', { items: [{ type: 'noop' }], errors: 'error' }, false],
  ['nonstring error item', { items: [{ type: 'noop' }], errors: [null] }, false],
  ['execution unavailable status', { items: [{ type: 'add_comment', body: unavailableBody }] }, true, unavailable],
  ['unavailable noop', { items: [{ type: 'noop' }] }, false, unavailable],
  ['unavailable findings disclosure', { items: [comment(), { type: 'submit_pull_request_review', body: 'Execution: infra-failure\nrestore failed; findings are source-only.' }] }, true, unavailable],
  ['missing findings execution disclosure', { items: [comment(), { type: 'submit_pull_request_review', body: 'Source-only finding.' }] }, false],
  ['unavailable status with collector error', { items: [{ type: 'add_comment', body: unavailableBody }], errors: ['collector failed'] }, false, unavailable],
  ['unavailable status mixed with noop', { items: [{ type: 'add_comment', body: unavailableBody }, { type: 'noop' }] }, false, unavailable],
  ['unavailable status mixed with findings', { items: [{ type: 'add_comment', body: unavailableBody }, comment(), review()] }, false, unavailable],
  ['duplicate unavailable status', { items: [{ type: 'add_comment', body: unavailableBody }, { type: 'add_comment', body: unavailableBody }] }, false, unavailable],
  ['unavailable status with unknown output', { items: [{ type: 'add_comment', body: unavailableBody }, { type: 'unknown' }] }, false, unavailable],
  ['unavailable status reason mismatch', { items: [{ type: 'add_comment', body: unavailableBody + 'x' }] }, false, unavailable],
  ['unavailable status class mismatch', { items: [{ type: 'add_comment', body: unavailableBody.replace('infra-failure', 'unsupported') }] }, false, unavailable],
  ['unavailable status trailing newline', { items: [{ type: 'add_comment', body: unavailableBody + '\n' }] }, false, unavailable],
  ['unavailable status when evidence available', { items: [{ type: 'add_comment', body: unavailableBody }] }, false],
  ['missing execution with noop', { items: [{ type: 'noop' }] }, false, { missing: true }],
  ['missing execution with stopped source review', stopped('report_incomplete'), true, { missing: true }],
  ['malformed execution JSON', { items: [{ type: 'noop' }] }, false, rawJson('{')],
  ['null execution', { items: [{ type: 'noop' }] }, false, null],
  ['array execution', { items: [{ type: 'noop' }] }, false, []],
  ['unknown execution class', { items: [{ type: 'noop' }] }, false, { ...available, classification: 'unknown' }],
  ['contradictory execution availability', { items: [{ type: 'noop' }] }, false, { ...unavailable, available: true }],
  ['nonboolean execution availability', { items: [{ type: 'noop' }] }, false, { ...available, available: 'true' }],
  ['empty execution reason', { items: [{ type: 'noop' }] }, false, { ...available, reason: '' }],
  ['multiline execution reason', { items: [{ type: 'noop' }] }, false, { ...available, reason: 'first\nsecond' }],
  ['oversized execution reason', { items: [{ type: 'noop' }] }, false, { ...available, reason: 'x'.repeat(241) }],
  ['not-applicable noop', { items: [{ type: 'noop' }] }, true, { ...available, classification: 'not-applicable' }],
  ['green-green noop', { items: [{ type: 'noop' }] }, true, { ...available, classification: 'green-green' }],
  ['stale execution head', { items: [{ type: 'noop' }] }, false, { ...available, headSha: 'd'.repeat(40) }],
  ['missing execution schema', { items: [{ type: 'noop' }] }, false, { ...available, schemaVersion: undefined }],
  ['unknown execution schema', { items: [{ type: 'noop' }] }, false, { ...available, schemaVersion: 2 }],
  ['invalid execution merge base', { items: [{ type: 'noop' }] }, false, { ...available, mergeBaseSha: 'invalid' }],
  ['invalid execution base tip', { items: [{ type: 'noop' }] }, false, { ...available, baseTipSha: 'invalid' }],
  ['execution claims authoritative evidence', { items: [{ type: 'noop' }] }, false, { ...available, supportingEvidenceOnly: false }],
  ['execution disclosure wrong class suffix', { items: [comment(), { type: 'submit_pull_request_review', body: 'Execution: red-green-verified' }] }, false],
  ['unavailable findings missing reason', { items: [comment(), { type: 'submit_pull_request_review', body: 'Execution: infra-failure' }] }, false, unavailable],
  ['retained Web.JS bold execution label', { items: [comment(), { type: 'submit_pull_request_review', body: '**Execution: red-green**\nSupporting evidence only.' }] }, true],
  ['retained QuickGrid bold execution sentence', { items: [comment(), { type: 'submit_pull_request_review', body: '**Execution: red-green.** Prepared evidence supports the selected tests.' }] }, true],
  ['execution Markdown heading', { items: [comment(), { type: 'submit_pull_request_review', body: '## Execution: red-green' }] }, true],
  ['execution bold label only', { items: [comment(), { type: 'submit_pull_request_review', body: '**Execution:** red-green' }] }, true],
  ['execution sentence punctuation', { items: [comment(), { type: 'submit_pull_request_review', body: 'Execution: red-green. Supporting evidence only.' }] }, true],
  ['execution inline-code class', { items: [comment(), { type: 'submit_pull_request_review', body: 'Execution: `red-green`' }] }, true],
  ['unavailable bold execution label', { items: [comment(), { type: 'submit_pull_request_review', body: '**Execution: infra-failure**\nrestore failed; findings are source-only.' }] }, true, unavailable],
  ['execution class word suffix', { items: [comment(), { type: 'submit_pull_request_review', body: 'Execution: red-greenish' }] }, false],
  ['execution wrong class', { items: [comment(), { type: 'submit_pull_request_review', body: 'Execution: green-green' }] }, false],
  ['execution mid-line label', { items: [comment(), { type: 'submit_pull_request_review', body: 'See Execution: red-green' }] }, false],
  ['execution unbalanced emphasis', { items: [comment(), { type: 'submit_pull_request_review', body: '**Execution: red-green' }] }, false],
  ['execution garbled label', { items: [comment(), { type: 'submit_pull_request_review', body: 'Exec*ution: red-green' }] }, false],
  ['execution list bullet', { items: [comment(), { type: 'submit_pull_request_review', body: '- Execution: red-green' }] }, false],
  ['execution bold class suffix', { items: [comment(), { type: 'submit_pull_request_review', body: '**Execution: red-green-verified**' }] }, false],
  ['execution code class suffix', { items: [comment(), { type: 'submit_pull_request_review', body: 'Execution: `red-green-verified`' }] }, false],
];

for (const runDirectory of process.argv.slice(2)) {
  const input = JSON.parse(fs.readFileSync(path.join(runDirectory, 'agent', 'agent_output.json'), 'utf8'));
  const execution = JSON.parse(fs.readFileSync(path.join(runDirectory, 'review-execution-validated', 'execution.json'), 'utf8'));
  cases.push([`retained collector ${path.basename(runDirectory)}`, input, true, execution, execution.headSha]);
}

const mismatches = [];
for (const filename of [workflowSource, workflowLock]) {
  const script = extractScript(filename);
  for (const [name, input, accepted, execution, headSha] of cases) {
    const result = execute(script, input, execution, headSha);
    if (result.error !== undefined) {
      mismatches.push(`${path.basename(filename)} ${name} threw instead of failing through core.setFailed: ${result.error}`);
    } else if ((result.failures.length === 0) !== accepted) {
      mismatches.push(
        `${path.basename(filename)} ${name} was ${result.failures.length === 0 ? 'accepted' : 'rejected'}: ${result.failures.join('; ')}`);
    }
  }
}

assert.equal(extractScript(workflowSource), extractScript(workflowLock),
  'The source and compiled workflow publication preflight scripts differ.');
assert.deepEqual(mismatches, [], mismatches.join('\n'));

console.log(`Validated ${cases.length} publication preflight cases against source and compiled lock.`);
