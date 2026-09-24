// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import * as fs from 'node:fs/promises';
import { devNull } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const script = fileURLToPath(import.meta.url);
const fullSha = /^[a-f0-9]{40}$/;
const repositoryName = /^[a-z0-9_.-]+\/[a-z0-9_.-]+$/i;
const hash = (bytes, algorithm = 'sha256') => createHash(algorithm).update(bytes).digest('hex');
const blobHash = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');

function requireValue(condition, message)
{
    if (!condition)
    {
        throw new Error(message);
    }
}

function run(command, args, options = {})
{
    try
    {
        return execFileSync(command, args, {
            maxBuffer: 64 * 1024 * 1024,
            windowsHide: true,
            ...options,
            env: options.env || { ...process.env, GIT_TERMINAL_PROMPT: '0' },
        });
    }
    catch (error)
    {
        throw new Error(`${command} failed: ${error.stderr?.toString().trim() || error.message}`, { cause: error });
    }
}

function git(directory, ...args)
{
    return run('git', ['-C', directory, ...args]);
}

function objects(directory, ...args)
{
    const env = { ...process.env };
    for (const key of Object.keys(env))
    {
        if (key.startsWith('GIT_CONFIG_') || ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE',
            'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_EXTERNAL_DIFF'].includes(key))
        {
            delete env[key];
        }
    }
    Object.assign(env, { GIT_CONFIG_GLOBAL: devNull, GIT_CONFIG_NOSYSTEM: '1', GIT_ATTR_NOSYSTEM: '1', GIT_TERMINAL_PROMPT: '0' });
    return run('git', ['--git-dir', directory, ...args], { env });
}

export function checkPaths(names)
{
    const files = new Set();
    const directories = new Set();
    for (const name of names)
    {
        const parts = name.split('/');
        requireValue(parts.every(part => part && part !== '.' && part !== '..'
            && !/[<>:"\\|?*\x00-\x1f]/.test(part) && !/[ .]$/.test(part)
            && !/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part)),
        `Cannot export this path portably: ${name}`);
        requireValue(parts.every(part => part.toLowerCase() !== '.git'), `Reserved Git path: ${name}`);
        const output = name.normalize('NFC').toLowerCase();
        requireValue(!files.has(output) && !directories.has(output), `Export path collision: ${name}`);
        files.add(output);
        const parents = output.split('/');
        parents.pop();
        while (parents.length)
        {
            const parent = parents.join('/');
            requireValue(!files.has(parent), `Export file/directory collision: ${name}`);
            directories.add(parent);
            parents.pop();
        }
    }
}

async function write(directory, name, bytes)
{
    const destination = path.join(directory, name);
    await fs.mkdir(path.dirname(destination), { recursive: true });
    await fs.writeFile(destination, bytes, { flag: 'wx', mode: 0o600 });
}

async function walk(directory, prefix = '', skipGit = false)
{
    const result = [];
    for (const entry of await fs.readdir(path.join(directory, prefix), { withFileTypes: true }))
    {
        const name = prefix ? `${prefix}/${entry.name}` : entry.name;
        if (skipGit && !prefix && entry.name === '.git')
        {
            continue;
        }
        requireValue(!entry.isSymbolicLink(), `Prepared input became a symlink: ${name}`);
        if (entry.isDirectory())
        {
            result.push(...await walk(directory, name, skipGit));
        }
        else
        {
            requireValue(entry.isFile(), `Prepared input is not an ordinary file: ${name}`);
            result.push(name);
        }
    }
    return result.sort();
}

async function directoryDigest(directory)
{
    const digest = createHash('sha256');
    const names = await walk(directory);
    for (const name of names)
    {
        digest.update(`${name}\0${hash(await fs.readFile(path.join(directory, name)))}\n`);
    }
    return { files: names.length, sha256: digest.digest('hex') };
}

function treeEntries(store, commit)
{
    return objects(store, 'ls-tree', '-r', '-z', '--full-tree', commit).toString('utf8').split('\0')
        .filter(Boolean).map(line =>
        {
            const tab = line.indexOf('\t');
            const [mode, type, sha] = line.slice(0, tab).split(' ');
            requireValue(tab > 0 && fullSha.test(sha) && ['blob', 'commit'].includes(type),
                'Malformed Git tree entry.');
            return { mode, type, sha, name: line.slice(tab + 1) };
        });
}

async function remoteGuidance(store, commit)
{
    const entries = treeEntries(store, commit).filter(entry => entry.name.endsWith('.md'));
    checkPaths(entries.map(entry => entry.name));
    return entries.map(entry =>
    {
        requireValue(entry.type === 'blob' && entry.mode !== '120000', `Guidance must be an ordinary file: ${entry.name}`);
        const body = objects(store, 'show', '--no-ext-diff', '--no-textconv', `${commit}:${entry.name}`);
        requireValue(blobHash(body) === entry.sha, `Guidance blob mismatch: ${entry.name}`);
        return { name: entry.name, body };
    });
}

async function localGuidance(root)
{
    root = git(root, 'rev-parse', '--show-toplevel').toString().trim();
    const names = [...new Set(git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '*.md')
        .toString('utf8').split('\0').filter(Boolean))].sort();
    const files = [];
    for (const name of names)
    {
        let stat;
        try
        {
            stat = await fs.lstat(path.join(root, name));
        }
        catch (error)
        {
            if (error.code === 'ENOENT')
            {
                continue; // A tracked deletion is part of the selected working tree.
            }
            throw error;
        }
        requireValue(stat.isFile(), `Guidance must be an ordinary file: ${name}`);
        files.push({ name, body: await fs.readFile(path.join(root, name)) });
    }
    checkPaths(files.map(file => file.name));
    const digest = createHash('sha256');
    for (const file of files)
    {
        digest.update(`${file.name}\0${hash(file.body)}\n`);
    }
    return {
        mode: 'local', originalRoot: root,
        checkoutCommit: git(root, 'rev-parse', 'HEAD').toString().trim(),
        workingTreeChanges: git(root, 'status', '--porcelain', '--untracked-files=all', '--', '*.md').length > 0,
        sha256: digest.digest('hex'), files,
    };
}

export function runtimeInput(name)
{
    const parts = name.split('/');
    return parts.some(part => ['.github', '.agents', '.copilot'].includes(part.toLowerCase()))
        || ['agents.md', 'claude.md', 'gemini.md', '.mcp.json'].includes(parts.at(-1).toLowerCase());
}

function guidanceOverlay(name)
{
    if (!runtimeInput(name))
    {
        return true;
    }
    return /(^|\/)(AGENTS|CLAUDE|GEMINI)\.md$/i.test(name)
        || name === '.github/copilot-instructions.md'
        || name.startsWith('.github/instructions/');
}

async function runtimeFiles(invocationRoot)
{
    const skillRoot = path.resolve(path.dirname(script), '..');
    const result = [];
    for (const name of await walk(skillRoot))
    {
        result.push({ name: `.github/skills/review-pull-request/${name}`, body: await fs.readFile(path.join(skillRoot, name)) });
    }
    const settings = '.github/copilot/settings.json';
    try
    {
        const body = await fs.readFile(path.join(invocationRoot, settings));
        JSON.parse(body);
        result.push({ name: settings, body });
    }
    catch (error)
    {
        if (error.code !== 'ENOENT')
        {
            throw error;
        }
    }
    return result;
}

async function validateWorkspace(output, manifest, runtime)
{
    const workspace = path.join(output, 'workspace');
    const store = path.join(workspace, '.git');
    requireValue((await fs.lstat(store)).isDirectory()
        && hash(await fs.readFile(path.join(store, 'config'))) === manifest.gitConfig
        && (await fs.readFile(path.join(store, 'info/attributes'), 'utf8')) === '* -text -ident -filter -working-tree-encoding\n',
    'Prepared Git configuration changed.');
    requireValue(objects(store, 'rev-parse', 'HEAD').toString().trim() === manifest.target.head, 'Prepared workspace is not at the frozen head.');
    for (const role of ['head', 'mergeBase', 'baseTip'])
    {
        requireValue(objects(store, 'rev-parse', `${manifest.target[role]}^{tree}`).toString().trim() === manifest.trees[role],
            `Missing or mismatched frozen originals: ${role}`);
    }
    objects(store, 'fsck', '--full', '--no-dangling', '--no-progress', ...new Set([
        manifest.target.head, manifest.target.mergeBase, manifest.target.baseTip,
    ]));
    const overlay = JSON.parse(await fs.readFile(path.join(output, 'overlay.json'), 'utf8'));
    const entries = treeEntries(store, manifest.target.head);
    requireValue(JSON.stringify(manifest.removedTargetPaths) === JSON.stringify(entries.filter(entry => runtimeInput(entry.name)).map(entry => entry.name)),
        'Prepared removal inventory does not match the frozen target.');
    const allowedOverlay = new Map();
    for (const name of await walk(path.join(output, 'guidance')))
    {
        if (manifest.guidance.mode === 'local' ? guidanceOverlay(name) : !runtimeInput(name))
        {
            allowedOverlay.set(name, hash(await fs.readFile(path.join(output, 'guidance', name))));
        }
    }
    for (const file of runtime)
    {
        allowedOverlay.set(file.name, hash(file.body));
    }
    requireValue(JSON.stringify(overlay.map(item => item.path).sort()) === JSON.stringify([...allowedOverlay.keys()].sort()),
        'Prepared overlay inventory does not match the selected guidance and installed runtime.');
    const expected = new Map(entries.filter(entry => entry.type === 'blob' && !runtimeInput(entry.name))
        .map(entry => [entry.name, entry.sha]));
    const overlayNames = new Set();
    for (const item of overlay)
    {
        requireValue(typeof item.path === 'string' && !overlayNames.has(item.path), 'Duplicate or invalid overlay path.');
        checkPaths([item.path]);
        overlayNames.add(item.path);
        const body = await fs.readFile(path.join(workspace, item.path));
        requireValue(hash(body) === item.sha256 && item.sha256 === allowedOverlay.get(item.path), `Modified reviewer overlay: ${item.path}`);
        expected.set(item.path, blobHash(body));
    }
    const actual = await walk(workspace, '', true);
    requireValue(JSON.stringify(actual) === JSON.stringify([...expected.keys()].sort()), 'Unexpected or missing workspace files, including instruction/configuration inputs.');
    for (const name of actual)
    {
        requireValue(blobHash(await fs.readFile(path.join(workspace, name))) === expected.get(name), `Modified prepared product file: ${name}`);
    }
    for (const file of runtime)
    {
        requireValue(overlay.find(item => item.path === file.name)?.sha256 === hash(file.body), `Installed reviewer runtime changed: ${file.name}`);
    }
}

export async function prepare(options, dependencies = {})
{
    requireValue(Number(process.versions.node.split('.')[0]) >= 22, 'Node.js 22 or newer is required.');
    requireValue(repositoryName.test(options.repo || '') && /^[1-9]\d*$/.test(String(options.pr)),
        'Specify --repo OWNER/REPO and --pr NUMBER; the invocation branch is not a review target.');
    requireValue(options.output, 'Specify a new --output directory, or --check an existing prepared directory.');
    requireValue(!options.head || fullSha.test(options.head), '--head must be a full immutable commit.');
    requireValue(!options.guidance || !options.guidanceRoot, 'Select either --guidance or --guidance-root.');
    const host = options.hostname || 'github.com';
    requireValue(/^[a-z0-9.-]+$/i.test(host), 'Invalid GitHub hostname.');
    run('git', ['--version']);
    run('gh', ['--version']);
    const api = dependencies.api || ((endpoint, accept) =>
    {
        const args = ['api', '--hostname', host, endpoint];
        if (accept)
        {
            args.push('-H', `Accept: ${accept}`);
        }
        const bytes = run('gh', args);
        return accept ? bytes : JSON.parse(bytes);
    });
    const repository = await api(`repos/${options.repo}`);
    requireValue(repositoryName.test(repository.full_name) && Number.isSafeInteger(repository.id), 'Invalid target repository metadata.');
    const endpoint = `repos/${repository.full_name}`;
    async function freeze()
    {
        const pull = await api(`${endpoint}/pulls/${options.pr}`);
        requireValue(pull.number === Number(options.pr) && pull.base?.repo?.id === repository.id
            && repositoryName.test(pull.head?.repo?.full_name || '') && fullSha.test(pull.head.sha),
        'GitHub did not identify the requested PR and its head repository.');
        requireValue(!options.head || options.head === pull.head.sha, 'The live PR head differs from the expected frozen head.');
        const base = await api(`${endpoint}/git/ref/heads/${encodeURIComponent(pull.base.ref)}`);
        requireValue(fullSha.test(base.object?.sha || ''), 'The base branch did not resolve to a full commit.');
        const comparison = await api(`${endpoint}/compare/${base.object.sha}...${pull.head.sha}`);
        requireValue(comparison.base_commit?.sha === base.object.sha && fullSha.test(comparison.merge_base_commit?.sha || ''),
            'GitHub did not return the expected immutable comparison identities.');
        return {
            identity: {
                hostname: host, repository: repository.full_name, repositoryId: repository.id, pr: pull.number,
                headRepository: pull.head.repo.full_name, head: pull.head.sha,
                baseRepository: pull.base.repo.full_name, baseRef: pull.base.ref,
                baseTip: base.object.sha, mergeBase: comparison.merge_base_commit.sha,
            },
            pull,
        };
    }
    const frozen = await freeze();
    const output = path.resolve(options.output);
    const producer = hash(await fs.readFile(script));
    const invocationRoot = options.guidanceRoot || process.cwd();
    const runtime = await runtimeFiles(invocationRoot);
    let guidance;
    if (options.guidance)
    {
        const [repo, commit, extra] = options.guidance.split('@');
        requireValue(!extra && repositoryName.test(repo || '') && fullSha.test(commit || ''), '--guidance requires OWNER/REPO@FULL_COMMIT.');
        const selected = await api(`repos/${repo}`);
        requireValue(repositoryName.test(selected.full_name), 'Invalid guidance repository.');
        guidance = { mode: 'remote', repository: selected.full_name, commit };
    }
    else
    {
        guidance = await localGuidance(options.guidanceRoot || process.cwd());
    }
    if (options.check)
    {
        const manifest = JSON.parse(await fs.readFile(path.join(output, 'manifest.json'), 'utf8'));
        requireValue(manifest.version === 2 && manifest.ready === true && manifest.producer === producer
            && manifest.workspace === 'workspace' && JSON.stringify(manifest.target) === JSON.stringify(frozen.identity),
        'Prepared input is stale, mismatched, or from a different preparation version.');
        requireValue(JSON.stringify(Object.keys(manifest.trees || {}).sort()) === JSON.stringify(['baseTip', 'head', 'mergeBase'])
            && manifest.guidance?.root === 'guidance'
            && JSON.stringify(Object.keys(manifest.artifacts || {}).sort()) === JSON.stringify(['diff.patch', 'files.json', 'overlay.json', 'pull.json']),
        'Prepared manifest omits required inputs.');
        for (const key of guidance.mode === 'local'
            ? ['mode', 'originalRoot', 'checkoutCommit', 'workingTreeChanges', 'sha256']
            : ['mode', 'repository', 'commit'])
        {
            requireValue(manifest.guidance[key] === guidance[key], `Prepared guidance mismatch: ${key}`);
        }
        const actual = await directoryDigest(path.join(output, 'guidance'));
        requireValue(actual.sha256 === manifest.guidance.sha256 && actual.files === manifest.guidance.files,
            'Incomplete or modified prepared guidance.');
        for (const [name, digest] of Object.entries(manifest.artifacts))
        {
            requireValue(!name.includes('/') && hash(await fs.readFile(path.join(output, name))) === digest, `Incomplete or modified input: ${name}`);
        }
        await validateWorkspace(output, manifest, runtime);
        return manifest;
    }
    await fs.mkdir(output);
    const workspace = path.join(output, 'workspace');
    const store = path.join(workspace, '.git');
    await fs.mkdir(workspace);
    objects(store, 'init', '--quiet', '--template=', '--object-format=sha1');
    objects(store, 'config', 'core.bare', 'false');
    objects(store, 'config', 'core.worktree', workspace);
    objects(store, 'config', 'core.hooksPath', path.join(store, 'disabled-hooks'));
    objects(store, 'config', 'core.autocrlf', 'false');
    objects(store, 'config', 'core.symlinks', 'false');
    objects(store, 'config', 'core.fsmonitor', 'false');
    objects(store, 'remote', 'add', 'origin', `https://${host}/${repository.full_name}.git`);
    await write(store, 'info/attributes', '* -text -ident -filter -working-tree-encoding\n');
    const fetch = dependencies.fetch || ((repo, commits, destination) =>
        objects(destination, '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential',
            'fetch', '--quiet', '--no-tags', '--depth=1', `https://${host}/${repo}.git`, ...commits));
    const groups = new Map();
    for (const [repo, commit] of [
        [frozen.identity.headRepository, frozen.identity.head],
        [frozen.identity.baseRepository, frozen.identity.baseTip],
        [frozen.identity.baseRepository, frozen.identity.mergeBase],
    ])
    {
        groups.set(repo, [...new Set([...(groups.get(repo) || []), commit])]);
    }
    for (const [repo, commits] of groups)
    {
        await fetch(repo, commits, store);
    }
    const files = [];
    for (let page = 1;; page++)
    {
        const batch = await api(`${endpoint}/pulls/${options.pr}/files?per_page=100&page=${page}`);
        requireValue(Array.isArray(batch), 'GitHub returned an invalid file list.');
        files.push(...batch);
        if (batch.length < 100)
        {
            break;
        }
    }
    requireValue(files.length === frozen.pull.changed_files && new Set(files.map(file => file.filename)).size === files.length,
        'GitHub returned an incomplete or duplicate changed-file list.');
    const changedPaths = objects(store, 'diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--name-only', '-z',
        frozen.identity.mergeBase, frozen.identity.head).toString('utf8').split('\0').filter(Boolean).sort();
    const listedPaths = [...new Set(files.flatMap(file => [file.filename, ...(file.previous_filename ? [file.previous_filename] : [])]))].sort();
    requireValue(JSON.stringify(changedPaths) === JSON.stringify(listedPaths), 'GitHub file list does not match the frozen trees.');
    for (const file of files)
    {
        const side = file.status === 'removed' ? frozen.identity.mergeBase : frozen.identity.head;
        requireValue(objects(store, 'rev-parse', `${side}:${file.filename}`).toString().trim() === file.sha,
            `GitHub file identity does not match the frozen tree: ${file.filename}`);
    }
    const diff = await api(`${endpoint}/pulls/${options.pr}`, 'application/vnd.github.diff');
    requireValue(Buffer.isBuffer(diff), 'GitHub did not return the authoritative diff bytes.');
    await write(output, 'diff.patch', diff);
    objects(store, 'read-tree', frozen.identity.mergeBase);
    if (diff.length)
    {
        objects(store, 'apply', '--cached', '--binary', '--whitespace=nowarn', path.join(output, 'diff.patch'));
    }
    requireValue(objects(store, 'write-tree').toString().trim()
        === objects(store, 'rev-parse', `${frozen.identity.head}^{tree}`).toString().trim(),
    'The authoritative diff does not reconstruct the frozen head; incomplete or unsupported diff.');
    await write(output, 'files.json', JSON.stringify(files, null, 2) + '\n');
    await write(output, 'pull.json', JSON.stringify(frozen.pull, null, 2) + '\n');
    const trees = {};
    for (const role of ['head', 'mergeBase', 'baseTip'])
    {
        trees[role] = objects(store, 'rev-parse', `${frozen.identity[role]}^{tree}`).toString().trim();
    }
    const entries = treeEntries(store, frozen.identity.head);
    checkPaths(entries.map(entry => entry.name));
    objects(store, 'read-tree', '--empty');
    objects(store, 'checkout', '--quiet', '--detach', frozen.identity.head);
    const removed = entries.filter(entry => runtimeInput(entry.name));
    for (const entry of removed)
    {
        if (entry.type === 'blob')
        {
            await fs.unlink(path.join(workspace, entry.name));
        }
        else
        {
            await fs.rmdir(path.join(workspace, entry.name));
        }
    }
    let selected;
    if (guidance.mode === 'remote')
    {
        const guidanceStore = path.join(output, '.guidance-objects');
        objects(guidanceStore, 'init', '--quiet', '--bare', '--template=', '--object-format=sha1');
        objects(guidanceStore, 'config', 'core.hooksPath', path.join(guidanceStore, 'disabled-hooks'));
        await fetch(guidance.repository, [guidance.commit], guidanceStore);
        selected = await remoteGuidance(guidanceStore, guidance.commit);
    }
    else
    {
        selected = guidance.files;
        delete guidance.files;
    }
    await fs.mkdir(path.join(output, 'guidance'));
    for (const file of selected)
    {
        await write(path.join(output, 'guidance'), file.name, file.body);
    }
    guidance = { ...guidance, root: 'guidance', ...await directoryDigest(path.join(output, 'guidance')) };
    if (guidance.mode === 'local')
    {
        requireValue((await localGuidance(guidance.originalRoot)).sha256 === guidance.sha256, 'Working-tree guidance changed during preparation.');
    }
    const overlays = new Map(selected.filter(file => guidance.mode === 'local'
        ? guidanceOverlay(file.name) : !runtimeInput(file.name)).map(file => [file.name, file.body]));
    for (const file of runtime)
    {
        overlays.set(file.name, file.body);
    }
    const overlay = [];
    for (const [name, body] of overlays)
    {
        checkPaths([name]);
        await fs.rm(path.join(workspace, name), { force: true });
        await write(workspace, name, body);
        overlay.push({ path: name, sha256: hash(body) });
    }
    await write(output, 'overlay.json', JSON.stringify(overlay, null, 2) + '\n');
    for (const name of ['docs/CrossCuttingGuidance.md', ...(files.some(file => /^src\/(Components|JSInterop)\//.test(file.filename))
        ? ['docs/BlazorComponentsGuidance.md'] : [])])
    {
        requireValue((await fs.readFile(path.join(output, 'guidance', name), 'utf8')).trim(),
            `Required guidance is empty: ${name}`);
    }
    requireValue(JSON.stringify((await freeze()).identity) === JSON.stringify(frozen.identity),
        'The target or base branch moved during preparation; no ready manifest was written.');
    const artifacts = {};
    for (const name of ['diff.patch', 'files.json', 'overlay.json', 'pull.json'])
    {
        artifacts[name] = hash(await fs.readFile(path.join(output, name)));
    }
    const manifest = {
        version: 2, ready: true, producer, target: frozen.identity, workspace: 'workspace', trees,
        gitConfig: hash(await fs.readFile(path.join(store, 'config'))),
        guidance, artifacts, removedTargetPaths: removed.map(entry => entry.name),
        originals: 'Use git -C WORKSPACE show --no-ext-diff --no-textconv FULL_SHA:REPOSITORY_PATH for overlaid/removed files and old/base-tip evidence.',
        limitations: 'No submodule or LFS initialization. Symlinks are link-text files, not dereferenced content. Required outside evidence remains incomplete until explicitly sourced.',
    };
    await validateWorkspace(output, manifest, runtime);
    await write(output, 'manifest.pending', JSON.stringify(manifest, null, 2) + '\n');
    await fs.rename(path.join(output, 'manifest.pending'), path.join(output, 'manifest.json'));
    return manifest;
}

if (process.argv[1] && path.resolve(process.argv[1]) === script)
{
    try
    {
        const { values } = parseArgs({ options: {
            repo: { type: 'string' }, pr: { type: 'string' }, output: { type: 'string' },
            head: { type: 'string' }, hostname: { type: 'string' }, guidance: { type: 'string' },
            'guidance-root': { type: 'string' }, check: { type: 'boolean' },
        } });
        const result = await prepare({ ...values, guidanceRoot: values['guidance-root'] });
        console.log(JSON.stringify({ manifest: path.join(path.resolve(values.output), 'manifest.json'), target: result.target, ready: true }));
    }
    catch (error)
    {
        console.error(`BLOCKED: ${error.message}`);
        process.exitCode = 1;
    }
}
