// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const tests = path.dirname(fileURLToPath(import.meta.url));
const skillRoot = path.dirname(tests);
const githubRoot = path.resolve(skillRoot, '../..');
const skillPath = path.join(skillRoot, 'SKILL.md');
const workflowPath = path.join(githubRoot, 'workflows/pull-request-review.md');

test('hosted original reads use the granted bare git show command', async () =>
{
    const [skill, workflow] = await Promise.all([
        fs.readFile(skillPath, 'utf8'),
        fs.readFile(workflowPath, 'utf8'),
    ]);

    assert.match(skill,
        /git show --no-ext-diff --no-textconv <full-frozen-SHA>:<repository-path>/);
    assert.match(skill,
        /Originals: <literal caller-selected original-file read command>\./);
    assert.doesNotMatch(skill,
        /Originals: git -C <workspace> show --no-ext-diff --no-textconv/);

    assert.match(workflow, /shell\(git show:\*\)/);
    assert.match(workflow,
        /The worker briefing's literal\s+original-file command is that same bare `git show` form\./);
    assert.match(workflow,
        /Never add `-C`, chain commands, use a\s+pipeline or wrapper/);
    assert.doesNotMatch(workflow, /shell\(git -C/);
});

test('local original reads retain an explicit workspace-specific command', async () =>
{
    const skill = await fs.readFile(skillPath, 'utf8');

    assert.match(skill,
        /git -C <literal-prepared-workspace> show --no-ext-diff --no-textconv <full-frozen-SHA>:<repository-path>/);
    assert.match(skill,
        /Local callers authorize the explicit workspace-specific\s+command when needed/);
});

test('hosted reviewer has no GitHub product-source reader', async () =>
{
    const workflow = await fs.readFile(workflowPath, 'utf8');

    assert.doesNotMatch(workflow, /github-get_file_contents/);
    assert.doesNotMatch(workflow, /allowed: \[[^\]]*get_file_contents/);
    assert.doesNotMatch(workflow, /github-search_code/);
    assert.match(workflow, /allowed: \[[^\]]*pull_request_read[^\]]*issue_read/);
});
