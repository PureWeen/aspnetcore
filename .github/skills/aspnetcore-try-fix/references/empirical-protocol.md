# Empirical candidate protocol

Read this reference only in `empirical` mode, together with the sibling
reviewer's `references/proof-calibration.md`.

## Assertion plan

Before editing, write:

```text
Setup:
Control:
Trigger:
Expected assertion:
Independent authority:
Allowed perturbations:
Impacted existing tests:
Suppressed interval:
Resume trigger:
Pre/post value generation:
Runtime variants:
Repetitions:
Regression assertion disposition:
Diagnostic mutation disposition:
```

Preserve the caller's assertion contract. A broader, easier stimulus is not
equivalent. Candidate-shaped thresholds remain diagnostic-only unless accepted
criteria require that exact result. Keep diagnostic assertion,
implementation-only, and combined diffs separate.

## Execution

Run mapped unchanged tests and the approved assertion on untouched frozen head
first. Do not create a mutation to manufacture red when head passes. Build,
harness, setup, stale-element, or infrastructure failures are `Blocked`, not a
behavioral red.

If head fails at the predicted assertion, apply one candidate and run the
identical assertion. Allow at most three implementation iterations for the same
hypothesis. Verify each execution matched setup, control, trigger, assertion,
runtime variants, and repetitions.

| Evidence | Result |
|---|---|
| Frozen head passes approved assertion | `Pass` with no defect; no correction |
| Behavioral red/green plus required producer and falsification cases pass | `Pass` |
| Targeted green but required producer/stress evidence incomplete | `Blocked` |
| Test or compile fails because of candidate | `Fail` |
| Required environment or faithful scenario unavailable | `Blocked` |

The first green proves only scoped causality. Vary dimensions that can falsify
the mechanism, not a generic matrix. Repeated identical passes are repeatability.
For recovery, exercise the first real producer event and opposite boundary. For
geometry/provenance, use a fixed control and bounded realistic variable
perturbation. For shared filters, cover mapped branches/consumers. For timeouts,
inspect and deterministically release inner work.

For serialization and compatibility claims, vary the bounded set of
representation and accessor/constructor paths that can change the external
contract, then run directly impacted unchanged tests. Do not promote one
targeted green while an affected producer/consumer variant remains untested.

A build-property bypass must be proven irrelevant and caps the result at
targeted-proven until standard build or exact CI passes. Disagreement among
timing-sensitive repetitions is `Fail` until explained. Never select only passing
runs.

`production-proven` requires every mapped unchanged test, a behavioral frozen-head
red, identical candidate green, real producer path, authoritative-enough oracle,
required regression, and relevant falsification cases. Otherwise preserve the
lower truthful label.
