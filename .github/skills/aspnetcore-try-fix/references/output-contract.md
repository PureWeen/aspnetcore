# Try-fix output contract

Read this reference only when writing the candidate artifact.

```markdown
## Try-Fix Candidate

**Mode:** candidate-review / empirical
**Approach:** <short name>
**Root-cause hypothesis:** <mechanism>
**Different from current fix:** <mechanism-level difference>
**Files:** <paths>
**Result:** Pass / Fail / Blocked / Proposed
**Product oracle:** documented / author-confirmed / test-encoded / inferred / unknown
**Oracle fidelity:** authoritative / corroborated / hypothesis / unknown
**Mechanism fidelity:** reproduced / structural / inferred / unknown
**Scenario fidelity:** exact / proxy / synthetic / missing
**Regression assertion disposition:** required-regression / optional-regression / rejected
**Diagnostic mutation disposition:** diagnostic-only / rejected / not-applicable

### Proposed change
<specific implementation>

### Evidence
<exact citations and observed output>

### Execution matrix
<one row per requested variant and repetition, or Not run in candidate-review>

### Impacted existing tests
<mapped unchanged tests, results, and justified exclusions>

### Recovery and provenance
<state/value generations and opposite boundary, or Not applicable>

### Proof status
- Finding: empirical / structural / missing
- Scenario: empirical / structural / missing
- Candidate: production-proven / targeted-proven / diagnostic-only / rejected / blocked
- Assertion fidelity: exact / scenario mismatch / incomplete

### Claim verification
- VERIFIED: <claim and source/output>
- CONTRADICTED: <claim and source/output>
- UNSUPPORTED: <claim or None>

### Adversarial findings
- <concrete issue or None>

### Tradeoffs
<complexity, compatibility, coverage>

### Recommendation
Keep current fix / prefer this candidate / combine specific parts
```

Write the complete response to `artifact_path` without overwriting another
candidate. Return the path to the orchestrator.
