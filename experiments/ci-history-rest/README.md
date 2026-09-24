# Experimental cross-build CI history: HTTP seam and offline demo

CI investigators repeatedly collect the same failure memberships across selected
builds. This experiment asks whether one bounded history query can provide that
membership while existing repository tools keep selection, evidence gathering
and policy. It is **not a deployed service, scanner replacement, flakiness
classifier or unquarantine proof**. Nothing here is imported by a workflow or
shipping framework code; all existing/default behavior stays unchanged.

This directory is the **one shared public demo** for the ASP.NET Core, MAUI,
runtime and SDK experiments. Consumer repositories point at an explicit
`--shared-root`; they do not copy the contract, client or server.

## Run from a clean checkout

Prerequisite: Python 3.10+ on Linux/macOS (stdlib only). No .NET SDK, packages,
Azure CLI, organization credentials, GitHub API, Kusto or remote requests are
needed. All build IDs and observations in `examples/` are synthetic.

From this repository's root:

```sh
SHARED_ROOT="$PWD/experiments/ci-history-rest"
python3 -B "$SHARED_ROOT/demo.py" \
  --fixture "$SHARED_ROOT/examples/aspnet-fixture.json" \
  --repository dotnet/aspnetcore \
  --query "$SHARED_ROOT/examples/aspnet-query.json" \
  --aspnet-adapter
python3 -B -m unittest discover -s "$SHARED_ROOT" -p 'test_*.py' -v
```

The demo starts a real HTTP listener on an ephemeral `127.0.0.1` port, generates
a temporary local test token, queries it through the shared client, prints JSON,
then closes its listener and removes the token. It owns no other processes.
Expected adapter output:

```json
{
  "dataCompleteness": "unknown",
  "methods": {
    "Example.Tests.Widget.RoundTrip": {"builds": [700001, 700002], "count": 2}
  },
  "notObservedBuildIds": [700003],
  "requiresVerificationBuildIds": [700001, 700002, 700003]
}
```

Omit `--aspnet-adapter` to print the full validated wire response. The same
one-shot command accepts another repository's synthetic fixture and query;
SDK can invoke it from Node and parse stdout. A failure exits nonzero with
diagnostics on stderr, never a successful empty history.

## Shared consumer interface

Given the explicit path to **this directory**, a Python consumer can use:

```python
import sys

sys.path.insert(0, str(shared_root))
from fixture_service import fixture_service

with fixture_service(fixture) as client:
    response = client.query("dotnet/maui", {
        "buildIds": [700001, 700002],
        "projection": "case",
        "outcome": "Failed",
        "filters": {"testName": "Example.Tests.Widget.RoundTrip", "arguments": ""},
    })
```

`fixture` is a dictionary, not a live backend. Its `builds` list declares
`id`, `repository.id`, `project.name` (`public`) and `definition.id`; its `rows`
list supplies source-shaped fields shown in the ASP.NET fixture. Set the
repository on those synthetic builds to match the query. Case rows require all
identity and reference columns; use explicit `null` for reported unavailable
values rather than omitting columns. Opaque arguments, hashes, queues and labels
are not normalized. `Message` is needed when filtering by `errorContains`.

`HistoryClient(base_url, token_file, *, output=None)` is also available in
`history_http_client.py`. It permits only explicit `http://127.0.0.1:PORT`
origins, disables environment proxies and redirects, validates successful
responses and raises `Problem(status, kind, detail)` for service errors.
Transport errors propagate. There are no implicit retries. Optional `output`
writes only new successful synthetic request/response files; it is **not** the
historical receipt/audit interface.

For a case query use exactly one of `outcome: "<literal>"` or `allOutcomes: true`.
For ASP.NET's lossy `methodBuilds` projection use only `outcome: "Failed"` and
omit `filters`. The caller must supply all selected build IDs (maximum 200);
there is no implicit time window or latest-build search.

## Where the ASP.NET adapter fits

The existing recurrence call sites are `source_a = enrich(aggregate(...))`
and `source_b = enrich(aggregate(b_ids))` in
[`test-quarantine.md`](../../.github/workflows/test-quarantine.md).
`aggregate` currently reads per-build failed results, normalizes source-method
names and counts at most one incident per method/build. It also supplies
representative records for `enrich`. **The adapter replaces only the membership
part, not that whole aggregate object or the `enrich` call.**

`aspnet_adapter.collect_method_builds(client, selected_ids)` obtains the combined
membership response. `project_methods(response, source_a_ids)` (and separately
`source_b_ids`) returns the existing `{method: {count, builds}}` slice. Its sorted
membership sets are not representative-occurrence order. Unresolved empty
method buckets are retained for the caller to handle, not silently verified.
The HTTP failure propagates before downstream decisions.

These responsibilities remain with the original scanner:

| Kept outside this seam | Why it must stay |
| --- | --- |
| Main/merged-PR selection, pipelines 83/87, time windows and build metadata | Explicit history IDs do not implement Source A/B selection or PR eligibility. |
| Representative ordering, failed-result pages, assembly/error/stack details and Source C crash extraction | `methodBuilds` deliberately has no case references or enrichment payload. |
| Full main-build timeline and existing regression proxy | Indexed failure absence is not an observed test pass. |
| Source-change eligibility, changed-test exclusions, thresholds and publication policy | History membership cannot authorize a quarantine action. |
| Positive verification and every required unknown/unmatched fallback | `notObservedBuildIds` means unknown, not passed; even indexed matches are unverified. |
| Existing unquarantine evidence requirements | Neither recurrence nor absence supplies complete passes or first-attempt proof. |

No workflow is wired to the adapter. A production integration would need an
explicit owner decision and the retained enrichment path, not a paste-over of
`aggregate`. The historical comparison used
[upstream source at `89c6e2e`](https://github.com/dotnet/aspnetcore/blob/89c6e2edf554324e111fd58f9838aa331165c23e/.github/workflows/test-quarantine.md),
not a claim that today's fork workflow was rerun end to end.

## Contract and what this harness proves

[`openapi.json`](openapi.json) is the approved external service design copied
**byte for byte**, SHA-256
`a3f63bb1d6d11455ca7fe569431051cfac88bd0427752247b5cd8962e9e7fe7e`.
It is not a shipping .NET API. Its only operation is
`POST /v1/repositories/{owner}/{repository}/test-history/query`.
Examples inside that immutable contract are illustrative, not refreshed results.

The request validator, response validator, reported-reference grouping and wire
projection were extracted from the closed spike. **The fixture server, lifecycle,
CLI and tests here are a new, reduced harness**, with no live/replay backend,
authenticated data-source access or private receipts. The fixture checks build
ownership only against synthetic declarations. It has no claim to authoritative
ownership, production authentication, admission/SLO behavior, cancellation or the
contract's 30-second source deadline. It implements neither production hosting
nor a second data collector.

Current tests cross real local sockets and cover exact case filtering, null
versus empty values, all-outcomes discovery, reference aliases/deduplication,
numeric `workItemId` versus physical `workItemName`, `helixJobId` from `JobName`,
method/build unions, unknowns, malformed queries/source data, atomic failures,
request/group/reference/response caps and owned-listener cleanup. Socket tests
reject nonlocal connections; no organizational source is consulted.
These new tests are **not the historical 333-request acceptance run**.

`queryCompleteness: complete` describes the bounded query, not ingestion.
`dataCompleteness` stays `unknown`, `identityVerification` stays `notChecked`,
and `snapshotConsistency` stays `notGuaranteed`. Build counts are memberships,
not executions or a failure-rate denominator.

## Retained historical findings (not measurements of this demo)

The closed spike used 194 selected ASP.NET builds. It preserved 40 Source A /
10 Source B method records, 535 / 55 method-build incidents, ten exact
pre-policy candidate sets and byte-equivalent downstream inputs. This was
bounded recurrence-input parity, **not a deployed full-scanner run**.

Comparable source work fell from 244 to 93 requests, but bytes rose from
592,619 to 1,280,759: **about 2.16x worse**, due to uncached ownership checks.
The compact client response is not the backend cost. `methodBuilds` preserves
compatibility; these results do not prove it necessary for response size.

All four final consumers passed one retained-source HTTP replay. Successful
live component checks also exist, but two final whole-live attempts failed
with dependency 503s: there was **no successful final whole-live invocation**.
SDK found six of seven indexed memberships yet produced identical dossiers and
the original 233 logical GETs / 52 unique requests even after synthetic group
suppression: **zero demonstrated source work eliminated**.

Complete ingestion, collector substitution, production auth/hosting/SLOs, and
full source-change eligibility/unquarantine proof remain unproved. The historical
fixture-source path/hash bookkeeping gap remains unsupported; this package
does not repair or republish those receipts. Raw captures and private evidence
roots are intentionally absent.

## Reviewer decision

Review whether this narrow membership seam is useful enough to pursue, which
retained enrichment/fallback obligations are acceptable, and whether ownership
cost outweighs reduced request count. This draft does not ask reviewers to
approve a deployment, change repository policy or infer that any test can be
quarantined or unquarantined.
