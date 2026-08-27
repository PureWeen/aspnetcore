#!/usr/bin/env bash
# Static prompt-contract regression test for issue-triage-agent.md.
#
# Verifies that the safe-output allow-list, Step 2 type rubric, and
# report template all agree on the same four issue types, and that
# the Task/docs and Bug-vs-Task guardrails are present in the rubric.
#
# This is NOT a model-classification or end-to-end eval. It tests the
# static contract surface of the prompt only.
#
# Usage: bash .github/evals/check-type-rubric.sh
# Exit 0 = pass, exit 1 = fail (with diagnostics).

set -uo pipefail
# Note: -e is intentionally omitted so that all six checks always run and
# report, even when grep finds no match (exit 1) on the pre-fix base.

WORKFLOW=".github/workflows/issue-triage-agent.md"
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Extraction helpers — every grep/pipeline that may legitimately produce no
# output is guarded with "|| true" so a missing element is reported as a
# check failure, not a silent script abort.
# ---------------------------------------------------------------------------
step2_section=$(sed -n '/^## Step 2: Type Classification$/,/^## Step [0-9]/p' "$WORKFLOW" | sed '$d' || true)

extract_rubric_types() {
  echo "$step2_section" | grep -oE '\| `[A-Za-z]+`' | sed 's/| `//;s/`//' | sort -u || true
}

# ---------------------------------------------------------------------------
# 1. Safe-output allow-list types (from set-issue-type.allowed)
# ---------------------------------------------------------------------------
allowlist_line=$(grep -A1 'set-issue-type:' "$WORKFLOW" | grep 'allowed:' || true)
allowlist_types=""
if [ -z "$allowlist_line" ]; then
  fail "Cannot find set-issue-type allowed list"
else
  allowlist_types=$(echo "$allowlist_line" | grep -oE '"[A-Za-z]+"' | tr -d '"' | sort -u || true)
  pass "Found safe-output allow-list: $(echo "$allowlist_types" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 2. Step 2 rubric must define exactly Bug, Epic, Feature, Task
# ---------------------------------------------------------------------------
rubric_types=$(extract_rubric_types)
expected_types="Bug
Epic
Feature
Task"

if [ "$rubric_types" = "$expected_types" ]; then
  pass "Step 2 rubric defines all four types: $(echo "$rubric_types" | tr '\n' ' ')"
else
  fail "Step 2 rubric types mismatch. Expected: $(echo "$expected_types" | tr '\n' ' ') Got: $(echo "$rubric_types" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 3. Allow-list and rubric must agree (set equality)
# ---------------------------------------------------------------------------
if [ -z "$allowlist_types" ]; then
  fail "Allow-list/rubric comparison skipped (allow-list not found)"
elif [ "$allowlist_types" = "$rubric_types" ]; then
  pass "Allow-list and rubric agree on types"
else
  fail "Allow-list and rubric disagree. Allow-list: $(echo "$allowlist_types" | tr '\n' ' ') Rubric: $(echo "$rubric_types" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 4. Report template **Type:** line must list all four types
#    Scoped to the Step 6 section (between "## Step 6" and "## Step 7")
# ---------------------------------------------------------------------------
step6_section=$(sed -n '/^## Step 6: Draft the Triage Comment$/,/^## Step [0-9]/p' "$WORKFLOW" | sed '$d' || true)
template_type_line=$(echo "$step6_section" | grep '^\*\*Type:\*\*' || true)

if [ -z "$template_type_line" ]; then
  fail "Cannot find **Type:** line in Step 6 report template"
else
  template_types=$(echo "$template_type_line" | grep -oE '`[A-Za-z]+`' | tr -d '`' | sort -u || true)
  if [ "$template_types" = "$expected_types" ]; then
    pass "Report template **Type:** line lists all four types"
  else
    fail "Report template **Type:** line missing types. Found: $(echo "$template_types" | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Task row in Step 2 rubric must mention docs sub-type
# ---------------------------------------------------------------------------
task_row=$(echo "$step2_section" | grep '| `Task`' || true)
if [ -z "$task_row" ]; then
  fail "Task rubric row not found in Step 2"
elif echo "$task_row" | grep -q 'docs'; then
  pass "Task rubric row references docs sub-type"
else
  fail "Task rubric row does not reference docs sub-type"
fi

# ---------------------------------------------------------------------------
# 6. Bug row in Step 2 rubric must include broken-behavior guardrail
# ---------------------------------------------------------------------------
bug_row=$(echo "$step2_section" | grep '| `Bug`' || true)
if [ -z "$bug_row" ]; then
  fail "Bug rubric row not found in Step 2"
elif echo "$bug_row" | grep -q 'broken.*behavior.*Bug\|current behavior is broken\|broken shipped behavior.*Bug'; then
  pass "Bug rubric row includes broken-behavior guardrail"
else
  fail "Bug rubric row lacks broken-behavior guardrail distinguishing Bug from Task"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$failures" -gt 0 ]; then
  echo "RESULT: $failures check(s) failed"
  exit 1
fi
echo "RESULT: All 6 checks passed"
exit 0
