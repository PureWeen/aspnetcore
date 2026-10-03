#!/usr/bin/env bash
# Trusted bounded runner. Run only against a disposable, frozen PR checkout.
set -euo pipefail
if [[ "${REVIEW_EXECUTION_BOUNDED:-}" != 1 ]]; then
  exec env REVIEW_EXECUTION_BOUNDED=1 timeout --signal=TERM --kill-after=30s 1800s bash "$0" "$@"
fi
deadline=$((SECONDS + 1740))
checkout=$(realpath "$1")
head=$2
base=$3
export REVIEW_EXECUTION_BASE_TIP=${5:-$base}
mkdir -p "$4"
output=$(realpath "$4")
mkdir -p "$output/logs"
cd "$checkout"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DISABLE_CUSTOM_PROMPT=1
export NUGET_PACKAGES="$checkout/.probe-nuget/packages"
export npm_config_cache="$checkout/.probe-npm-cache"
export NUGET_ENHANCED_MAX_NETWORK_TRY_COUNT=1 NUGET_ENHANCED_NETWORK_RETRY_DELAY_MILLISECONDS=100
unset GH_TOKEN GITHUB_TOKEN COPILOT_GITHUB_TOKEN

# Keep the planner and report writer with the trusted wrapper, not in the PR tree.
report() {
  python3 - "$output" "$checkout" "$head" "$base" "$@" <<'PY'
import ast, datetime, fnmatch, json, pathlib, re, subprocess, sys, xml.etree.ElementTree as ET
out, root, head, base = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
mode, args = sys.argv[5], sys.argv[6:]
path = out / 'execution.json'
def save(d):
    path.write_text(json.dumps(d, indent=2) + '\n')
def git(*args):
    return subprocess.check_output(['git', *args], cwd=root)
def inputs_match(d, tree):
    paths = d['revertedFiles'] if tree == 'reverted' else []
    changed = set(git('diff', '--name-only', '--no-renames', '-z', head).decode().split('\0')) - {''}
    return changed <= set(paths) and (not paths or subprocess.run(
        ['git', 'diff', '--quiet', base, '--', *paths], cwd=root).returncode == 0)
def product_path(name):
    p = pathlib.PurePosixPath(name)
    return p.suffix not in ('.csproj', '.props', '.targets') and p.name.lower() not in (
        'nuget.config', 'package.json', 'global.json') and name.startswith((
        'src/Components/QuickGrid/Microsoft.AspNetCore.Components.QuickGrid/src/',
        'src/Components/Web.JS/src/'))
def mask(text):
    tokens = r'//[^\n]*|/\*[\s\S]*?\*/|("""+)[\s\S]*?\1|@"(?:""|[^"])*"|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`(?:\\.|[^`\\])*`'
    return re.sub(tokens, lambda m: re.sub(r'[^\n]', ' ', m[0]), text)
def closing(code, start, opening, ending):
    depth = 0
    for i in range(start, len(code)):
        depth += (code[i] == opening) - (code[i] == ending)
        if depth == 0:
            return i + 1
    raise ValueError('unbalanced test declaration')
def changed_lines(name, status):
    if status == 'A':
        return None
    diff = git('diff', '--unified=0', base, head, '--', name).decode()
    return [(max(int(s), 1), max(int(s), 1) + max(int(n or '1'), 1) - 1)
        for s, n in re.findall(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', diff, re.M)]
def touched(text, start, end, lines):
    a, b = text.count('\n', 0, start) + 1, text.count('\n', 0, end) + 1
    return lines is None or any(a <= d and c <= b for c, d in lines)
def require_covered_changes(code, lines, spans):
    if lines is not None:
        source_lines = code.splitlines()
        for start, end in lines:
            for line in range(start, end + 1):
                if line > len(source_lines) or source_lines[line - 1].strip() and not any(a <= line <= b for a, b in spans):
                    raise ValueError('changed setup/helper or declaration outside selected tests is unsupported')
def changed_methods(text, lines):
    code = mask(text)
    if len(re.findall(r'\bnamespace\s+[\w.]+', code)) != 1:
        raise ValueError('exactly one C# namespace per test file is supported')
    namespace = re.search(r'\bnamespace\s+([\w.]+)', code)
    classes = []
    for m in re.finditer(r'\b((?:(?:public|private|internal|protected|partial|sealed|abstract)\s+)*)class\s+(\w+)[^{;]*\{', code):
        start = m.end() - 1
        classes.append((m.group(2), 'public' in m.group(1).split(), start, closing(code, start, '{', '}'),
            bool(re.match(r'\s*<', code[m.end(2):start]))))
    methods, rows, spans = [], {}, []
    pattern = r'((?:\s*\[[^\]]+\])+)\s*public\s+(?:async\s+)?[\w.<>,?\[\]]+\s+(\w+)\s*\([^;{]*\)\s*(\{|=>)'
    for m in re.finditer(pattern, code):
        attributes = m.group(1)
        if not re.search(r'\[(?:Fact|Theory)\b', attributes):
            continue
        attribute_start = code.index('[', m.start(1), m.end(1))
        start = m.end() - len(m.group(3))
        end = closing(code, start, '{', '}') if m.group(3) == '{' else code.index(';', start) + 1
        if not touched(text, attribute_start, end, lines):
            continue
        owners = [c for c in classes if c[2] < attribute_start < c[3]]
        if len(owners) != 1 or not owners[0][1] or owners[0][4] or namespace is None:
            raise ValueError('only non-nested, non-generic public test classes with a namespace are supported')
        name = namespace.group(1) + '.' + owners[0][0] + '.' + m.group(2)
        methods.append(name)
        spans.append((text.count('\n', 0, attribute_start) + 1, text.count('\n', 0, end) + 1))
        if re.search(r'\[Fact\b', attributes):
            rows[name] = 1
        elif not re.search(r'\[(?:MemberData|ClassData)\b', attributes):
            rows[name] = len(re.findall(r'\[InlineData\b', attributes))
    require_covered_changes(code, lines, spans)
    if lines is None and len(methods) != len(re.findall(r'\[(?:Fact|Theory)\b', code)):
        raise ValueError('unsupported attributed C# test declaration')
    return sorted(set(methods)), rows
def changed_jest_names(text, lines):
    code = mask(text)
    calls = []
    literal = r"""(?P<title>'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")"""
    for m in re.finditer(r'\b(describe|test|it)(?:\.(?:only|skip|todo))?\s*\(\s*' + literal, text):
        if not code[m.start():].startswith(m.group(1)):
            continue
        start = code.index('(', m.start())
        end = closing(code, start, '(', ')')
        title = ast.literal_eval(m.group('title'))
        if '\n' in title or '\r' in title:
            raise ValueError('multiline Jest test names are unsupported')
        calls.append((m.group(1), title, m.start(), end))
    selected, spans = [], []
    for kind, title, start, end in calls:
        if kind == 'describe' or not touched(text, start, end, lines):
            continue
        parents = [c[1] for c in calls if c[0] == 'describe' and c[2] < start < c[3]]
        selected.append(' '.join([*parents, title]))
        spans.append((text.count('\n', 0, start) + 1, text.count('\n', 0, end) + 1))
    if re.search(r'\b(?:test|it|describe)\s*\.\s*each\b|\b(?:test|it|describe)\s+(?:as\b|:)', code):
        raise ValueError('dynamic/parameterized or aliased Jest declarations are unsupported')
    require_covered_changes(code, lines, spans)
    return sorted(set(selected))
if mode == 'init':
    assert git('rev-parse', 'HEAD').decode().strip() == head, 'checkout is not the frozen head'
    assert not git('status', '--porcelain', '--untracked-files=no'), 'tracked checkout must be clean'
    data = git('diff', '--name-status', '--no-renames', '-z', base, head).decode().split('\0')
    files, plans, unsupported = [], {}, []
    for i in range(0, len(data)-1, 2):
        status, name = data[i:i+2]
        p = pathlib.PurePosixPath(name)
        is_test = any(s.lower() in ('test', 'tests', 'testassets') for s in p.parts)
        is_test |= bool(re.search(r'\.(?:test\.(?:ts|js)|spec\.ts)$', name))
        docs = p.suffix.lower() in ('.md', '.rst', '.adoc') and not name.startswith('.github/workflows/')
        kind = 'test' if is_test else ('docs-only' if docs else 'product')
        files.append({'status': status, 'path': name, 'kind': kind})
        if not is_test:
            if kind == 'product' and not product_path(name):
                unsupported.append({'path': name, 'reason': 'product path outside measured prototype'})
            continue
        if any('e2e' in s.lower() or 'selenium' in s.lower() for s in p.parts):
            unsupported.append({'path': name, 'reason': 'unsupported: browser E2E'})
            continue
        if status == 'D':
            unsupported.append({'path': name, 'reason': 'deleted test has no head test to execute'})
            continue
        if status not in ('A', 'M'):
            unsupported.append({'path': name, 'reason': 'unsupported file change status'})
            continue
        if p.suffix == '.cs':
            project = None
            for parent in (root / p).parents:
                if parent == root.parent:
                    break
                candidates = sorted(set(parent.glob('*.Tests.csproj')) | set(parent.glob('*.Test.csproj')))
                if candidates:
                    if len(candidates) == 1:
                        project = candidates[0].relative_to(root).as_posix()
                    break
            text = (root / p).read_text()
            try:
                methods, rows = changed_methods(text, changed_lines(name, status))
                if status == 'M':
                    old_methods, _ = changed_methods(git('show', base + ':' + name).decode(), None)
                    all_methods, _ = changed_methods(text, None)
                    if set(old_methods) - set(all_methods):
                        unsupported.append({'path': name, 'reason': 'removed C# test methods have no head case to execute'})
            except (ValueError, SyntaxError) as error:
                unsupported.append({'path': name, 'reason': str(error)})
                continue
            if (project == 'src/Components/QuickGrid/Microsoft.AspNetCore.Components.QuickGrid/test/Microsoft.AspNetCore.Components.QuickGrid.Tests.csproj'
                    and methods):
                item = plans.setdefault(('dotnet', project), {'kind': 'dotnet', 'project': project,
                    'files': [], 'methods': [], 'expectedRows': {}, 'filter': ''})
                item['files'].append(name)
                item['methods'] = sorted(set(item['methods'] + methods))
                item['expectedRows'].update(rows)
                item['filter'] = '|'.join('FullyQualifiedName='+m for m in item['methods'])
            else:
                unsupported.append({'path': name, 'reason': 'outside measured QuickGrid planner or no changed attributed test method'})
        elif re.search(r'\.(?:test\.(?:ts|js)|spec\.ts)$', name):
            pkg = None
            for parent in (root / p).parents:
                if parent == root:
                    break
                if (parent / 'package.json').exists():
                    pkg = parent
                    break
            manifest = json.loads((pkg/'package.json').read_text()) if pkg else {}
            workspaces = json.loads((root/'package.json').read_text()).get('workspaces', []) if (root/'package.json').exists() else []
            if isinstance(workspaces, dict):
                workspaces = workspaces.get('packages', [])
            member = pkg and any(fnmatch.fnmatch(pkg.relative_to(root).as_posix(), w.rstrip('/')) for w in workspaces)
            if (name.startswith('src/Components/Web.JS/') and member and
                    manifest.get('name') == '@microsoft/microsoft.aspnetcore.components.web.js' and
                    'jest' in manifest.get('scripts', {}).get('test', '')):
                workspace = manifest['name']
                try:
                    names = changed_jest_names((root / p).read_text(), changed_lines(name, status))
                    if status == 'M':
                        old_names = changed_jest_names(git('show', base + ':' + name).decode(), None)
                        all_names = changed_jest_names((root / p).read_text(), None)
                        if set(old_names) - set(all_names):
                            unsupported.append({'path': name, 'reason': 'removed Jest tests have no head case to execute'})
                except (ValueError, SyntaxError) as error:
                    unsupported.append({'path': name, 'reason': str(error)})
                    continue
                if not names:
                    unsupported.append({'path': name, 'reason': 'no changed statically named Jest test; helper-only changes are unsupported'})
                    continue
                # Separate plans prevent one file's name pattern from selecting unrelated cases in another file.
                item = plans.setdefault(('jest', name), {'kind': 'jest', 'workspace': workspace,
                    'files': [], 'paths': [], 'names': names, 'newFile': status == 'A',
                    'filter': '|'.join('^'+re.escape(n)+'$' for n in names)})
                item['files'].append(name)
                item['paths'].append((root/p).relative_to(pkg).as_posix())
            else:
                unsupported.append({'path': name, 'reason': 'outside measured Web.JS planner or no owning Jest workspace'})
        else:
            unsupported.append({'path': name, 'reason': 'support/testassets change is not a directly runnable test'})
    for f in files:
        if f['kind'] != 'product':
            continue
        kind = ('dotnet' if f['path'].startswith('src/Components/QuickGrid/Microsoft.AspNetCore.Components.QuickGrid/src/')
            else 'jest' if f['path'].startswith('src/Components/Web.JS/src/') else None)
        if kind and not any(p['kind'] == kind for p in plans.values()):
            unsupported.append({'path': f['path'], 'reason': 'no changed supported tests for this product area'})
    d = {'schemaVersion': 1, 'headSha': head, 'mergeBaseSha': base,
        'baseTipSha': __import__('os').environ['REVIEW_EXECUTION_BASE_TIP'],
        'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'changedFiles': files, 'plan': list(plans.values()), 'unsupported': unsupported, 'steps': [],
        'results': [], 'revertedFiles': [], 'classification': 'pending',
        'scope': 'changed QuickGrid methods (all rows) / new Jest files or changed static Jest cases; project-to-project dependencies allowed',
        'cachePolicy': 'fresh checkout-local NuGet/npm caches; no Actions cache'}
    if not plans:
        if any(f['kind'] != 'docs-only' for f in files) and not unsupported:
            unsupported.append({'path': '', 'reason': 'no changed supported runnable tests'})
        d['classification'] = 'unsupported' if unsupported else 'not-applicable'
        d['reason'] = '; '.join(sorted(set(u['reason'] for u in unsupported))) if unsupported else (
            'docs-only; no build or test' if files and all(f['kind']=='docs-only' for f in files) else 'no changed runnable tests')
    save(d)
elif mode == 'step':
    d = json.loads(path.read_text())
    label, tree, start, end, code, command, log = args
    text = pathlib.Path(log).read_text(errors='replace')
    # Bound every retained log to 96 KiB, preserving both ends.
    raw = text.encode()
    if len(raw) > 98304:
        text = raw[:49152].decode(errors='replace') + '\n... [middle truncated] ...\n' + raw[-49152:].decode(errors='replace')
        pathlib.Path(log).write_text(text)
    errors = [line for line in text.splitlines() if re.search(r'error|failed|exception|ECONN|NU\d{4}', line, re.I)]
    d['steps'].append({'phase': label, 'tree': {'headSha': head, 'revertedFiles': d['revertedFiles'] if tree=='reverted' else []},
        'startedEpoch': float(start), 'endedEpoch': float(end), 'seconds': round(float(end)-float(start),3),
        'exitCode': int(code), 'command': command, 'cwd': str(root),
        'log': str(pathlib.Path(log).relative_to(out)), 'errorExcerpt': '\n'.join(errors[:12])[:5000]})
    save(d)
elif mode == 'revert':
    d = json.loads(path.read_text())
    d['revertedFiles'] = [f['path'] for f in d['changedFiles'] if f['kind']=='product' and product_path(f['path'])]
    save(d)
elif mode == 'check-inputs':
    sys.exit(0 if inputs_match(json.loads(path.read_text()), args[0]) else 1)
elif mode == 'test':
    d = json.loads(path.read_text())
    kind, tree, filename, exit_code, plan_index = args
    file = pathlib.Path(filename)
    r = {'planIndex': int(plan_index), 'kind': kind, 'tree': tree, 'exitCode': int(exit_code), 'passed': 0, 'failed': 0,
        'skipped': 0, 'total': 0, 'report': str(file.relative_to(out)), 'testCases': [], 'reportFound': file.exists()}
    r['preservedHeadInputs'] = inputs_match(d, tree)
    if file.exists() and kind == 'dotnet':
        x = ET.parse(file).getroot()
        ns = {'t': 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010'}
        c = x.find('.//t:Counters', ns)
        if c is not None:
            r.update(total=int(c.get('total',0)), passed=int(c.get('passed',0)), failed=int(c.get('failed',0)),
                skipped=int(c.get('notExecuted',0)))
        for t in x.findall('.//t:UnitTestResult', ns):
            name = t.get('testName', '')
            message = ''.join(t.find('.//t:Message', ns).itertext()) if t.find('.//t:Message', ns) is not None else ''
            stack = ''.join(t.find('.//t:StackTrace', ns).itertext()) if t.find('.//t:StackTrace', ns) is not None else ''
            body_reached = name.split('(')[0] + '(' in stack
            failure_kind = ('assertion' if body_reached and re.search(r'\bAssert\.\w+\(\) Failure', message)
                else 'test-body-exception' if body_reached else 'setup-or-unclassified')
            r['testCases'].append({'name': name, 'outcome': t.get('outcome'), 'message': message[:2000],
                'stack': stack[:1000] + stack[-1000:] if len(stack) > 2000 else stack, 'failureKind': failure_kind})
    elif file.exists():
        j = json.loads(file.read_text())
        r.update(total=j.get('numTotalTests',0), passed=j.get('numPassedTests',0), failed=j.get('numFailedTests',0),
            skipped=j.get('numPendingTests',0)+j.get('numTodoTests',0), runtimeErrorSuites=j.get('numRuntimeErrorTestSuites',0))
        for suite in j.get('testResults', []):
            source = pathlib.Path(suite.get('name', ''))
            source = source.relative_to(root).as_posix() if source.is_relative_to(root) else ''
            for a in suite.get('assertionResults', []):
                message = '\n'.join(a.get('failureMessages', []))
                body_reached = '_callCircusTest' in message and '_callCircusHook' not in message
                failure_kind = ('assertion' if body_reached and re.search(r'\bexpect\(.+\)\.', message)
                    else 'test-body-exception' if body_reached else 'setup-or-unclassified')
                r['testCases'].append({'name': a.get('fullName'), 'file': source, 'outcome': a.get('status'),
                    'message': message[:2000], 'failureKind': failure_kind})
    r['failureKinds'] = {name: sum(c['outcome'].lower() == 'failed' and c['failureKind'] == name for c in r['testCases'])
        for name in ('assertion', 'test-body-exception', 'setup-or-unclassified')}
    # No executed tests can never be a green result.
    if not r['reportFound'] or r['exitCode'] not in (0, 1):
        r['classification'] = 'infra-failure'
    elif r['passed']+r['failed'] == 0:
        r['classification'] = 'infra-failure' if r.get('runtimeErrorSuites') else 'zero-tests'
    elif r.get('runtimeErrorSuites'):
        r['classification'] = 'infra-failure'
    elif any(c['outcome'].lower() == 'failed' and c['failureKind'] == 'setup-or-unclassified' for c in r['testCases']):
        r['classification'] = 'infra-failure'
    elif r['exitCode'] == 0 and r['failed'] == 0:
        r['classification'] = 'pass'
    elif r['failed'] > 0:
        r['classification'] = 'fail'
    else:
        r['classification'] = 'infra-failure'
    d['results'].append(r)
    save(d)
    print(r['classification'])
elif mode == 'failure':
    d = json.loads(path.read_text())
    d['classification'], d['reason'] = args
    save(d)
elif mode == 'finish':
    d = json.loads(path.read_text())
    if d['classification'] == 'pending':
        pairs = []
        for i in range(len(d['plan'])):
            a = next((r for r in d['results'] if r['planIndex']==i and r['tree']=='head'), None)
            b = next((r for r in d['results'] if r['planIndex']==i and r['tree']=='reverted'), None)
            pairs.append('red-green' if a and b and a['classification']=='pass' and b['classification']=='fail'
                else 'green-green' if a and b and a['classification']=='pass' and b['classification']=='pass'
                else 'infra-failure')
        d['classification'] = pairs[0] if len(set(pairs))==1 and not d['unsupported'] else 'mixed'
        d['planClassifications'] = pairs
        d['reason'] = ('partial unsupported selection; see unsupported paths and per-plan outcomes'
            if d['unsupported'] else 'head/reverted outcomes: '+', '.join(pairs))
        if 'red-green' in pairs and not d['revertedFiles']:
            d['classification'], d['reason'] = 'infra-failure', 'assertions failed on identical product trees; no reverted product change'
    d['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    d['restoredHead'] = git('rev-parse','HEAD').decode().strip()==head and not git('status','--porcelain','--untracked-files=no')
    if not d['restoredHead']:
        d['classification'], d['reason'] = 'infra-failure', 'disposable tracked tree restoration failed'
    save(d)
    lines = ['# Deterministic review execution', '', f"**{d['classification']}** — {d.get('reason','')}",
        f"Head `{head}`; merge base `{base}`; restored tracked head: {d['restoredHead']}.",
        '', '| Phase | Seconds | Exit | Exact command |', '|---|---:|---:|---|']
    lines += [f"| {s['phase']} | {s['seconds']} | {s['exitCode']} | `{s['command'].replace('|','&#124;')}` |" for s in d['steps']]
    lines += ['', '| Tree | Passed | Failed | Skipped | Total |', '|---|---:|---:|---:|---:|']
    lines += [f"| {r['tree']} (plan {r['planIndex']}) | {r['passed']} | {r['failed']} | {r['skipped']} | {r['total']} |" for r in d['results']]
    lines += ['', 'Reverted product files:'] + ['- `'+p+'`' for p in d['revertedFiles']]
    for s in d['steps']:
        if s['exitCode'] and s['errorExcerpt']:
            lines += ['', '## '+s['phase'], '```text', s['errorExcerpt'], '```']
    for r in d['results']:
        failures = [t for t in r['testCases'] if t['outcome'].lower() in ('failed','fail')]
        if failures:
            lines += ['', '## '+r['tree']+' first failure ('+failures[0]['failureKind']+')', '```text',
                failures[0]['name'], failures[0]['message'], failures[0].get('stack', ''), '```']
    (out/'execution.md').write_text('\n'.join(lines)+'\n')
PY
}

run_step() {
  local phase=$1 tree=$2
  shift 2
  local start end code command log
  start=$(date +%s.%N)
  log="$output/logs/$phase.log"
  printf -v command '%q ' "$@"
  printf '%s\tstart\t%s\t%s\n' "$start" "$phase" "$tree" >> "$output/phases.tsv"
  set +e
  local remaining=$((deadline - SECONDS))
  if ((remaining <= 0)); then
    code=124
    printf 'Overall execution deadline exceeded\n' > "$log"
  else
    ((remaining <= 600)) || remaining=600
    timeout --signal=TERM --kill-after=15s "${remaining}s" "$@" >"$log" 2>&1
    code=$?
  fi
  set -e
  end=$(date +%s.%N)
  printf '%s\tend\t%s\t%s\n' "$end" "$phase" "$tree" >> "$output/phases.tsv"
  report step "$phase" "$tree" "$start" "$end" "$code" "$command" "$log"
  printf '%s: exit %s, log %s\n' "$phase" "$code" "$log"
  step_code=$code
}

finish() {
  local code=$?
  trap - EXIT
  set +e
  # Restore only probe-reverted paths, including files deleted at head, on all exits.
  if [[ -f "$output/revert-paths.z" ]]; then
    while IFS= read -r -d '' file; do
      if git cat-file -e "$head:$file" 2>/dev/null; then
        git checkout "$head" -- "$file"
      else
        git rm -f --ignore-unmatch -- "$file"
      fi
    done < "$output/revert-paths.z"
  fi
  if [[ $code != 0 && -f "$output/execution.json" ]]; then
    report failure infra-failure "wrapper exit $code; see wrapper log"
  fi
  [[ ! -f "$output/execution.json" ]] || report finish
  exit "$code"
}
trap finish EXIT
trap 'exit 124' TERM INT
report init
plan_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["plan"]))' "$output/execution.json")
if [[ "$plan_count" == 0 ]]; then
  exit 0
fi

managed=false
for ((i=0; i<plan_count; i++)); do
  kind=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan"][int(sys.argv[2])]["kind"])' "$output/execution.json" "$i")
  [[ "$kind" != dotnet ]] || managed=true
done
if [[ "$managed" == true ]]; then
  run_step sdk-install head bash -c 'set -eo pipefail; source ./activate.sh; source ./eng/common/tools.sh; InitializeDotNetCli true'
  if [[ "$step_code" != 0 ]]; then
    report failure infra-failure 'SDK install failed before tests'
    exit 0
  fi
fi

plan_fields() {
  python3 - "$output/execution.json" "$1" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))['plan'][int(sys.argv[2])]
print(p['kind'])
print(p.get('project',p.get('workspace')))
print(p.get('filter',''))
for f in p.get('paths',[]): print(f)
PY
}
declare -A restored
for ((i=0; i<plan_count; i++)); do
  readarray -t fields < <(plan_fields "$i")
  kind=${fields[0]}
  target=${fields[1]}
  restore_key="$kind:$target"
  [[ -z "${restored[$restore_key]:-}" ]] || continue
  restored[$restore_key]=1
  if [[ "$kind" == dotnet ]]; then
    restore_args=(./eng/build.sh --restore --no-build --build-managed --no-build-native --no-build-nodejs --no-build-java --no-build-installers --projects "$checkout/$target" -p:UseIisNativeAssets=false -p:BuildNodeJS=false)
    run_step "restore-$i" head "${restore_args[@]}"
  else
    npm_args=(npm ci "--workspace=$target" --include-workspace-root --loglevel=http)
    run_step "restore-$i" head "${npm_args[@]}"
  fi
  if [[ "$step_code" != 0 ]]; then
    report failure infra-failure "restore-$i failed before tests"
    exit 0
  fi
  if [[ "$kind" == dotnet && "$target" == src/Components/* ]]; then
    run_step "assets-build-$i" head bash -c 'set -eo pipefail; source ./activate.sh; dotnet build src/Assets/Microsoft.AspNetCore.App.Internal.Assets.csproj --no-restore -t:Build -v:minimal -p:UseIisNativeAssets=false -p:BuildNodeJS=false'
    if [[ "$step_code" != 0 ]]; then
      report failure infra-failure "assets-build-$i failed before tests"
      exit 0
    fi
  fi
done

for tree in head reverted; do
  if [[ "$tree" == reverted ]]; then
    report revert
    python3 - "$output/execution.json" "$output/revert-paths.z" <<'PY'
import json,sys
open(sys.argv[2],'wb').write(b''.join(p.encode()+b'\0' for p in json.load(open(sys.argv[1]))['revertedFiles']))
PY
    while IFS= read -r -d '' file; do
      if git cat-file -e "$base:$file" 2>/dev/null; then
        git checkout "$base" -- "$file"
      else
        git rm -f --ignore-unmatch -- "$file"
      fi
    done < "$output/revert-paths.z"
    git diff --name-status "$head" > "$output/reverted-tree.txt"
  fi
  for ((i=0; i<plan_count; i++)); do
    readarray -t fields < <(plan_fields "$i")
    kind=${fields[0]}
    target=${fields[1]}
    if [[ "$kind" == dotnet ]]; then
      run_step "build-$tree-$i" "$tree" bash -c 'set -eo pipefail; source ./activate.sh; dotnet build "$1" --no-restore -v:minimal -p:UseIisNativeAssets=false -p:BuildNodeJS=false' _ "$target"
      if [[ "$step_code" != 0 ]]; then
        if [[ "$tree" == reverted ]] && grep -Eq 'error (CS[0-9]+|RZ[0-9]+)' "$output/logs/build-$tree-$i.log"; then
          report failure red-compile "build-$tree-$i: compiler diagnostics after reverting product files"
        else
          report failure infra-failure "build-$tree-$i failed before tests"
        fi
        exit 0
      fi
      test_report="$output/$tree-$i.trx"
      if ! report check-inputs "$tree"; then
        report failure infra-failure "build-$tree-$i changed preserved tracked inputs or the intended product tree"
        exit 0
      fi
      rm -f -- "$test_report"
      run_step "test-$tree-$i" "$tree" bash -c 'set -eo pipefail; source ./activate.sh; dotnet test "$1" --no-build --no-restore --filter "$2" --logger "trx;LogFileName=$3" --results-directory "$4" -v:normal -p:UseIisNativeAssets=false -p:BuildNodeJS=false' _ "$target" "${fields[2]}" "$tree-$i.trx" "$output"
    else
      test_report="$output/$tree-$i.jest.json"
      if ! report check-inputs "$tree"; then
        report failure infra-failure "test-$tree-$i has changed preserved tracked inputs or the wrong product tree"
        exit 0
      fi
      rm -f -- "$test_report"
      # Jest transforms TypeScript itself: no separate workspace bundle build is needed.
      run_step "test-$tree-$i" "$tree" npm test "--workspace=$target" -- --runInBand --runTestsByPath "${fields[@]:3}" "--testNamePattern=${fields[2]}" --reporters=default --no-cache --json "--outputFile=$test_report"
    fi
    outcome=$(report test "$kind" "$tree" "$test_report" "$step_code" "$i")
    if [[ "$outcome" == zero-tests || "$outcome" == infra-failure ]]; then
      report failure "$outcome" "test-$tree-$i: no successful executed-test evidence"
      exit 0
    elif [[ "$tree" == head && "$outcome" == fail ]]; then
      report failure head-red "test-$tree-$i fails at frozen head"
      exit 0
    fi
  done
done
