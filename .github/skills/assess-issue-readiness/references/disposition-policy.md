# Deterministic disposition policy

Evaluate rows from top to bottom. The first true condition is the sole primary
disposition. Lower rows may appear only as supporting findings.

| Precedence | Condition | Primary disposition | Allowed reason code | Next route |
|---:|---|---|---|---|
| 1 | `security_report` | `security_process_required` | `security_boundary` | `security_reporting_process` |
| 2 | `verified_duplicate` or `verified_already_fixed` | `duplicate_or_already_fixed` | `duplicate_verified`, `already_fixed_verified` | `existing_issue_or_release` |
| 3 | `verified_by_design` | `by_design` | `upstream_by_design_verified` | `stop_by_design` |
| 4 | `unsupported_usage` | `unsupported_usage` | `unsupported_configuration_verified` | `supported_usage_guidance` |
| 5 | `invalid_or_incomplete_setup` | `invalid_or_incomplete_setup` | `setup_invalid`, `setup_incomplete` | `reporter_setup_correction` |
| 6 | `documentation_gap` | `documentation_gap` | `documentation_gap_verified` | `documentation_owner` |
| 7 | `product_or_design_decision_required` | `product_or_design_decision_required` | `product_decision_needed`, `api_design_needed` | `maintainer_design_decision` |
| 8 | `runtime_reproduced` or `structural_failure_verified` | `ready_for_fix_investigation` | `runtime_failure_reproduced`, `structural_failure_verified` | `fix_investigation` |
| 9 | `required_reporter_evidence_missing` | `needs_reporter_evidence_or_repro` | `reporter_repro_missing`, `environment_details_missing` | `reporter_evidence` |
| 10 | `infrastructure_blocked` | `infrastructure_blocked_or_inconclusive` | `environment_blocked`, `tooling_blocked` | `infrastructure_or_retry` |
| 11 | `runtime_attempted` and not `runtime_reproduced` | `not_reproduced` | `bounded_repro_did_not_reproduce` | `maintainer_recheck_or_reporter_evidence` |
| 12 | `below_threshold` | `deferred_below_threshold` | `insufficient_customer_or_release_signal` | `defer` |
| 13 | Otherwise | `infrastructure_blocked_or_inconclusive` | `insufficient_evidence` | `maintainer_recheck_or_reporter_evidence` |

## Interpretation rules

- A duplicate or already-fixed result requires a verified canonical issue, PR, or
  released version in `resolution_reference`, bound to decisive evidence. Similar
  wording is only a supporting finding.
- `by_design` requires an existing maintainer decision or authoritative contract.
  The assessor does not create product intent. Cite passed `history` or
  `documentation` evidence, not generic triage metadata.
- `unsupported_usage` requires authoritative support documentation. Lack of a
  matching sample is not proof.
- Setup mistakes outrank a reproduction result because the reported configuration
  did not exercise the supported product contract.
- `documentation_gap` is primary only when expected runtime behavior is established
  and the actionable defect is missing or incorrect documentation.
- `product_or_design_decision_required` needs passed `history` or `documentation`
  evidence showing the unresolved decision boundary.
- `ready_for_fix_investigation` is a route, not a bug verdict. When
  `runtime_evidence_feasible` is true, it requires a passed reproduction check with
  evidence. When false, `structural_failure_verified` needs direct compiler,
  contract, or equivalent non-runtime evidence and an explanation.
- `not_reproduced` never recommends closing an issue. It routes to recheck or
  additional evidence.
- Missing upstream triage signals never become locally re-derived signals.
- `deferred_below_threshold` needs passed `proportionality` evidence recording the
  customer/release signals and bounded-depth rationale.

## Execution safety

Reporter-controlled project and build files are executable input. A receipt with
`runtime_attempted: true` is valid only when it records credential-free sandbox
execution, no external network access, and only explicit artifact, disposable
worktree, cache, and temp writable roots. Interactive browser/app traffic may use
recorded loopback access. No writable root or runtime working directory may
overlap the user's source worktree.

If those controls are unavailable, set `infrastructure_blocked` and do not run the
repro. Command checks reject recorded GitHub mutations, `git push`, non-GET
`gh api`, or mutating `curl` methods, but those checks are attestation validation,
not prevention. A hard guarantee additionally requires an externally enforced
credential-free boundary with no remote-write tools.
