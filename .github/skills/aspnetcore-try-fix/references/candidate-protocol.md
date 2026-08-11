# Candidate-review protocol

Read this reference only in `candidate-review` mode.

Start from the frozen evidence manifest. Inspect target code, surrounding files,
callers, mapped tests, and relevant instructions before reading the current fix
in detail. Narrow lookups must record the path and claim they verify.

State:

- the observable failure, product oracle, and its authority;
- one mechanism-level root-cause hypothesis;
- the producer path and smallest distinguishing assertion;
- mapped unchanged tests and uncovered producer branches;
- why the candidate differs from current and prior approaches.

For stateful behavior, write the transition table requested by the orchestrator.
For suppressed/deferred callbacks or measurements, trace the first recovery
producer event, ownership transfer, value generation/provenance, stale state,
and opposite boundary. Keep the adjacent matrix proportional.

Choose exactly one candidate. Prefer restoring information at the
producer/consumer contract, established repository patterns, minimal compatibility
surface, and real runtime dispatch. Reject symptom suppression, duplicate
hypotheses, and unrelated refactoring. `NO VIABLE ALTERNATIVE` is valid only
after naming and rejecting one real mechanism-level alternative.

Attack the candidate with a concrete scenario:

- Which call path, target framework, producer branch, or consumer bypasses it?
- Are existing handlers, public API, and serialization peers preserved?
- Can the proposed test pass without the reported bug?
- Is its expected result independently required?
- What happens for default/repeated/opposite transitions, cancellation,
  disposal, delayed/out-of-order delivery, partial batches, and no-op work when
  those dimensions apply?

Return `Proposed`, never `Pass`, because candidate review does not execute the
behavior.
