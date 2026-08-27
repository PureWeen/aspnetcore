#!/usr/bin/env bash
# Focused eval: verify the issue-triage-agent prompt's type rubric covers
# Task and Epic, and that the report template lists all four types.
# Red/green: fails against the pre-fix prompt, passes after the fix.
#
# Usage: bash .github/evals/check-type-rubric.sh
# Exit 0 = pass, exit 1 = fail (with diagnostics).

set -euo pipefail

WORKFLOW=".github/workflows/issue-triage-agent.md"
FIXTURE=".github/evals/issue-triage-type-65910.json"
failures=0

# 1. Type rubric must define Task
if ! grep -q '| `Task`' "$WORKFLOW"; then
  echo "FAIL: Type rubric missing Task definition"
  failures=$((failures + 1))
else
  echo "PASS: Type rubric defines Task"
fi

# 2. Type rubric must define Epic
if ! grep -q '| `Epic`' "$WORKFLOW"; then
  echo "FAIL: Type rubric missing Epic definition"
  failures=$((failures + 1))
else
  echo "PASS: Type rubric defines Epic"
fi

# 3. Report template must list all four types
if ! grep -q 'Bug.*Feature.*Task.*Epic' "$WORKFLOW"; then
  echo "FAIL: Report template does not list all four types (Bug | Feature | Task | Epic)"
  failures=$((failures + 1))
else
  echo "PASS: Report template lists Bug | Feature | Task | Epic"
fi

# 4. Task definition must mention docs subtype
if ! grep -q 'Task.*docs' "$WORKFLOW"; then
  echo "FAIL: Task definition does not reference docs sub-type"
  failures=$((failures + 1))
else
  echo "PASS: Task definition references docs sub-type"
fi

# 5. Bug-vs-Task guardrail: Bug definition should mention broken behavior
if ! grep -q 'Bug.*broken.*behavior\|Bug.*current behavior is broken' "$WORKFLOW"; then
  echo "FAIL: Bug definition lacks broken-behavior guardrail"
  failures=$((failures + 1))
else
  echo "PASS: Bug definition includes broken-behavior guardrail"
fi

# 6. Fixture file exists and has expected type=Task
if [ ! -f "$FIXTURE" ]; then
  echo "FAIL: Fixture file missing: $FIXTURE"
  failures=$((failures + 1))
else
  expected_type=$(python3 -c "import json; print(json.load(open('$FIXTURE'))['expected']['issue_type'])" 2>/dev/null || echo "")
  if [ "$expected_type" = "Task" ]; then
    echo "PASS: Fixture expects issue_type=Task for #65910"
  else
    echo "FAIL: Fixture expected issue_type should be Task, got: $expected_type"
    failures=$((failures + 1))
  fi
fi

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "RESULT: $failures check(s) failed"
  exit 1
fi

echo ""
echo "RESULT: All checks passed"
exit 0
