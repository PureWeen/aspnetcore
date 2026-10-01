"""Fresh synthetic socket checks, not a rerun of the historical acceptance suite."""

import copy
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

from aspnet_adapter import collect_method_builds, fallback_build_ids, project_methods
from fixture_service import fixture_service
from history_http_client import HistoryClient
from history_http_common import CONTRACT_SHA256, MAX_REQUEST, Problem, digest, encode


ROOT = Path(__file__).resolve().parent
QUERY = {"buildIds": [700003, 700002, 700001], "projection": "case", "outcome": "Failed"}


def fixture():
    return json.loads((ROOT / "examples/aspnet-fixture.json").read_text())


def row(**changes):
    return {**fixture()["rows"][0], **changes}


def raw_request(client, body, *, method="POST", repository="dotnet/aspnetcore", headers=None):
    parsed = urlsplit(client.base_url)
    connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=3)
    fields = {"Content-Type": "application/json",
              "Authorization": "Bearer " + client.token_file.read_text()}
    fields.update(headers or {})
    try:
        connection.request(method, f"/v1/repositories/{repository}/test-history/query", body, fields)
        response = connection.getresponse()
        data = response.read()
        return response.status, dict(response.headers), json.loads(data) if data else None
    finally:
        connection.close()


class DemoTests(unittest.TestCase):
    def setUp(self):
        original = socket.socket.connect

        def loopback_only(sock, address):
            if not isinstance(address, tuple) or address[0] != "127.0.0.1":
                raise AssertionError(f"Nonlocal socket denied: {address!r}")
            return original(sock, address)

        self.guard = patch.object(socket.socket, "connect", loopback_only)
        self.guard.start()
        self.addCleanup(self.guard.stop)

    def test_contract_pin_and_examples(self):
        raw = (ROOT / "openapi.json").read_bytes()
        self.assertEqual(CONTRACT_SHA256, digest(raw))
        contract = json.loads(raw)
        examples = contract["paths"]["/v1/repositories/{owner}/{repository}/test-history/query"][
            "post"]["requestBody"]["content"]["application/json"]["examples"]
        with fixture_service(fixture()) as client:
            for name, example in examples.items():
                with self.subTest(example=name):
                    result = client.query("dotnet/aspnetcore", example["value"])
                    self.assertEqual("unknown", result["dataCompleteness"])

    def test_case_identity_references_and_unknown(self):
        data = fixture()
        data["rows"] += [row(), row(Arguments="other", ArgumentHash="other")]
        with fixture_service(data) as client:
            result = client.query("dotnet/aspnetcore", QUERY)
        self.assertEqual([700003], result["notObservedBuildIds"])
        self.assertEqual(3, len(result["groups"]))
        self.assertEqual(1, len(result["groups"][0]["references"]))
        ref = result["groups"][0]["references"][0]
        self.assertEqual(1, ref["workItemId"])
        self.assertEqual("synthetic-physical-work", ref["workItemName"])
        self.assertEqual("synthetic-job", ref["helixJobId"])

    def test_method_union_and_aspnet_subset_not_execution_count(self):
        data = fixture()
        data["rows"] += [row(), row(TestName="Example.Tests.Widget.RoundTrip(value: 9)")]
        with fixture_service(data) as client:
            result = collect_method_builds(client, QUERY["buildIds"])
        name = "Example.Tests.Widget.RoundTrip"
        self.assertEqual({name: {"count": 2, "builds": [700001, 700002]}},
                         project_methods(result, QUERY["buildIds"]))
        self.assertEqual({name: {"count": 1, "builds": [700002]}}, project_methods(result, [700002]))
        self.assertEqual({}, project_methods(result, []))
        self.assertEqual([700001, 700002, 700003], fallback_build_ids(result))
        self.assertEqual([700002, 700003], fallback_build_ids(result, [700001]))
        with self.assertRaises(ValueError):
            project_methods(result, [999999])
        with self.assertRaises(ValueError):
            fallback_build_ids(result, [999999])

    def test_zero_rows_still_unknown(self):
        data = fixture()
        data["rows"] = []
        with fixture_service(data) as client:
            result = collect_method_builds(client, QUERY["buildIds"])
        self.assertEqual([], result["groups"])
        self.assertEqual(sorted(QUERY["buildIds"]), result["notObservedBuildIds"])
        self.assertEqual("unknown", result["dataCompleteness"])
        self.assertEqual("notChecked", result["identityVerification"])
        self.assertEqual("notGuaranteed", result["snapshotConsistency"])

    def test_all_outcomes_preserves_null_empty_and_new_values(self):
        data = fixture()
        data["rows"] = [row(Outcome=value) for value in (None, "", "Passed", "FutureOutcome")]
        with fixture_service(data) as client:
            result = client.query("dotnet/aspnetcore", {
                "buildIds": [700001], "projection": "case", "allOutcomes": True,
            })
        self.assertEqual({None, "", "Passed", "FutureOutcome"},
                         {g["identity"]["outcome"] for g in result["groups"]})

    def test_null_empty_and_exact_case_sensitive_filters(self):
        data = fixture()
        data["rows"] = [row(Arguments=None), row(Arguments=""), row(Arguments="value: 1")]
        with fixture_service(data) as client:
            for filters, expected in [
                ({"arguments": ""}, 1),
                ({"arguments": "", "errorContains": "Illustrative"}, 1),
                ({"arguments": "", "errorContains": "illustrative"}, 0),
                ({"arguments": "", "pipelineId": 87}, 0),
                ({"arguments": "value: 1", "queue": "synthetic-queue",
                  "argumentHash": "synthetic-one", "testRunName": "synthetic-run",
                  "workItemFriendlyName": "synthetic-work", "testName": row()["TestName"]}, 1),
            ]:
                with self.subTest(filters=filters):
                    result = client.query("dotnet/aspnetcore", {**QUERY, "filters": filters})
                    self.assertEqual(expected, len(result["groups"]))

    def test_reference_aliases_do_not_merge_cases(self):
        data = fixture()
        data["rows"] = [row(Arguments="None"), row(Arguments="Asynchronous")]
        with fixture_service(data) as client:
            result = client.query("dotnet/aspnetcore", QUERY)
        self.assertEqual(2, len(result["groups"]))
        self.assertEqual(result["groups"][0]["references"], result["groups"][1]["references"])

    def test_partial_and_missing_references(self):
        data = fixture()
        empty = row(TestRunId=None, TestResultId=None, JobName="", WorkItemId=None, WorkItemName=None)
        data["rows"] = [empty, {**empty, "WorkItemId": 4}]
        with fixture_service(data) as client:
            result = client.query("dotnet/aspnetcore", QUERY)
        group = result["groups"][0]
        self.assertTrue(group["hasUnreferencedObservations"])
        self.assertEqual(1, len(group["references"]))
        self.assertEqual(4, group["references"][0]["workItemId"])
        self.assertIsNone(group["references"][0]["helixJobId"])

    def test_malformed_source_fails_instead_of_empty_success(self):
        variants = [
            row(TestResultId=1.5), row(TestRunId=True), row(WorkItemId=0),
            row(WorkItemId=9007199254740992), row(JobName=123), row(TestName=123),
        ]
        missing = row()
        del missing["Arguments"]
        variants.append(missing)
        for bad in variants:
            with self.subTest(row=bad):
                data = fixture()
                data["rows"] = [bad]
                with fixture_service(data) as client, self.assertRaises(Problem) as error:
                    client.query("dotnet/aspnetcore", QUERY)
                self.assertEqual(502, error.exception.status)

    def test_empty_method_bucket_is_not_discarded(self):
        data = fixture()
        data["rows"] = [row(TestName=None), row(TestName=" (unresolved)")]
        with fixture_service(data) as client:
            result = collect_method_builds(client, QUERY["buildIds"])
        self.assertEqual({"": {"count": 1, "builds": [700001]}}, project_methods(result, [700001]))
        self.assertEqual([700001, 700002, 700003], fallback_build_ids(result))

    def test_source_failures_propagate(self):
        for kind, status in [("partial", 502), ("invalid", 502), ("unavailable", 503)]:
            with self.subTest(kind=kind):
                data = {**fixture(), "fault": {"kind": kind}}
                with fixture_service(data) as client, self.assertRaises(Problem) as error:
                    collect_method_builds(client, QUERY["buildIds"])
                self.assertEqual(status, error.exception.status)

    def test_scope_failure_is_atomic(self):
        for change in ("missing", "foreign", "project"):
            data = fixture()
            if change == "missing":
                data["builds"].pop()
            elif change == "foreign":
                data["builds"][2]["repository"]["id"] = "dotnet/maui"
            else:
                data["builds"][2]["project"]["name"] = "unavailable"
            with self.subTest(change=change), fixture_service(data) as client:
                status, _, value = raw_request(client, encode(QUERY))
                self.assertEqual(404, status)
                self.assertNotIn("groups", value)

    def test_invalid_queries_rejected_on_wire(self):
        invalid = [
            {}, {**QUERY, "buildIds": []}, {**QUERY, "buildIds": [True]},
            {**QUERY, "buildIds": [1.5]}, {**QUERY, "buildIds": [0]},
            {**QUERY, "buildIds": [2147483648]}, {**QUERY, "buildIds": [700001, 700001]},
            {**QUERY, "buildIds": list(range(1, 202))},
            {**QUERY, "projection": "unknown"}, {**QUERY, "other": 1},
            {**QUERY, "allOutcomes": True}, {**QUERY, "filters": {}},
            {**QUERY, "filters": None}, {**QUERY, "filters": {"other": ""}},
            {**QUERY, "filters": {"testName": ""}},
            {**QUERY, "filters": {"arguments": "x" * 8193}},
            {**QUERY, "filters": {"pipelineId": True}},
            {**QUERY, "filters": {"queue": "\ud800"}},
            {**QUERY, "projection": "methodBuilds", "filters": {"queue": ""}},
            {**QUERY, "projection": "methodBuilds", "outcome": "Passed"},
            {"buildIds": [700001], "projection": "case", "allOutcomes": False},
            {"buildIds": [700001], "projection": "methodBuilds", "allOutcomes": True},
        ]
        with fixture_service(fixture()) as client:
            for query in invalid:
                with self.subTest(query=query):
                    status, _, value = raw_request(client, encode(query))
                    self.assertEqual(400, status)
                    self.assertNotIn("groups", value)
            for raw in (b'{"buildIds":[1],"buildIds":[2]}', b'{"x":NaN}', b"\xff", b"{"):
                with self.subTest(raw=raw):
                    self.assertEqual(400, raw_request(client, raw)[0])

    def test_http_envelope_errors(self):
        with fixture_service(fixture()) as client:
            for status, options in [
                (401, {"headers": {"Authorization": ""}}),
                (415, {"headers": {"Content-Type": "text/plain"}}),
                (404, {"repository": "dotnet/other"}),
                *[(405, {"method": method}) for method in ("GET", "PUT", "DELETE", "HEAD", "PATCH", "OPTIONS", "TRACE")],
            ]:
                with self.subTest(options=options):
                    actual, headers, value = raw_request(client, encode(QUERY), **options)
                    self.assertEqual(status, actual)
                    self.assertEqual("no-store", headers["Cache-Control"])
                    self.assertEqual("application/problem+json", headers["Content-Type"])
                    if value is not None:
                        self.assertEqual(headers["X-Request-ID"], value["requestId"])
            self.assertEqual(413, raw_request(client, b" " * (MAX_REQUEST + 1))[0])

    def test_200_build_boundary(self):
        data = fixture()
        data["builds"] = [{**data["builds"][0], "id": bid} for bid in range(1, 201)]
        data["rows"] = []
        with fixture_service(data) as client:
            result = collect_method_builds(client, list(range(1, 201)))
        self.assertEqual(200, len(result["notObservedBuildIds"]))

    def test_group_and_reference_caps_are_atomic(self):
        for count, field, limit in [(500, "Arguments", 500), (250, "TestResultId", 250)]:
            for extra in (0, 1):
                with self.subTest(field=field, extra=extra):
                    data = fixture()
                    data["rows"] = [row(**{field: str(i) if field == "Arguments" else i + 1})
                                    for i in range(count + extra)]
                    with fixture_service(data) as client:
                        status, _, value = raw_request(client, encode(QUERY))
                    self.assertEqual(200 if extra == 0 else 422, status)
                    if extra:
                        self.assertNotIn("groups", value)
                    else:
                        actual = len(value["groups"]) if field == "Arguments" else len(value["groups"][0]["references"])
                        self.assertEqual(limit, actual)

    def test_total_reference_and_response_byte_caps(self):
        for groups, expected in [(8, 200), (9, 422)]:
            data = fixture()
            data["rows"] = [row(Arguments=str(g), TestResultId=i + 1) for g in range(groups) for i in range(250)]
            with self.subTest(groups=groups), fixture_service(data) as client:
                self.assertEqual(expected, raw_request(client, encode(QUERY))[0])
        data = fixture()
        data["rows"] = [row(Arguments="x" * (2 * 1024 * 1024))]
        with fixture_service(data) as client:
            status, _, result = raw_request(client, encode(QUERY))
            self.assertEqual(422, status)
            self.assertNotIn("groups", result)

    def test_client_rejects_bad_response_and_tolerates_additive_fields(self):
        with fixture_service(fixture()) as client:
            baseline = client.query("dotnet/aspnetcore", QUERY)
            for field, replacement in [
                ("repository", "dotnet/maui"), ("dataCompleteness", "complete"),
                ("queryCompleteness", "partial"), ("notObservedBuildIds", []),
                ("queryCompletedAt", "2000-01-01T00:00:00+00:00"),
            ]:
                bad = {**baseline, field: replacement}
                with self.subTest(field=field), patch("fixture_service.fixture_result", return_value=bad):
                    with self.assertRaises(ValueError):
                        client.query("dotnet/aspnetcore", QUERY)
            good = copy.deepcopy(baseline)
            good["futureMetadata"] = "ignored"
            good["groups"][0]["identity"]["futureIdentity"] = "ignored"
            with patch("fixture_service.fixture_result", return_value=good):
                self.assertEqual(good, client.query("dotnet/aspnetcore", QUERY))

    def test_all_four_repository_consumers_use_same_transport(self):
        for repo in ("aspnetcore", "maui", "runtime", "sdk"):
            data = fixture()
            for build in data["builds"]:
                build["repository"]["id"] = f"dotnet/{repo}"
            with self.subTest(repo=repo), fixture_service(data) as client:
                self.assertEqual(f"dotnet/{repo}", client.query(f"dotnet/{repo}", QUERY)["repository"])

    def test_environment_proxy_is_not_used(self):
        with patch.dict(os.environ, {"http_proxy": "http://192.0.2.1:9", "no_proxy": ""}):
            with fixture_service(fixture()) as client:
                self.assertEqual("complete", client.query("dotnet/aspnetcore", QUERY)["queryCompleteness"])

    def test_client_only_accepts_explicit_loopback_origin(self):
        for origin in ("https://127.0.0.1:80", "http://localhost:80", "http://192.0.2.1:80",
                       "http://127.0.0.1:80/path", "http://user@127.0.0.1:80"):
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                HistoryClient(origin, "not-read")

    def test_listener_and_credential_cleanup_even_on_failure(self):
        with self.assertRaisesRegex(RuntimeError, "stop"):
            with fixture_service(fixture()) as client:
                client.query("dotnet/aspnetcore", QUERY)
                port = urlsplit(client.base_url).port
                credential = client.token_file
                raise RuntimeError("stop")
        self.assertFalse(credential.exists())
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", port), timeout=1)

    def test_transport_failure_is_not_empty_result(self):
        with fixture_service(fixture()) as client:
            client.query("dotnet/aspnetcore", QUERY)
        with fixture_service(fixture()) as active:
            stopped = HistoryClient(client.base_url, active.token_file)
            with self.assertRaises(OSError):
                stopped.query("dotnet/aspnetcore", QUERY)

    def test_cli_from_another_directory(self):
        result = subprocess.run([
            sys.executable, "-B", str(ROOT / "demo.py"),
            "--fixture", str(ROOT / "examples/aspnet-fixture.json"),
            "--repository", "dotnet/aspnetcore", "--query", str(ROOT / "examples/aspnet-query.json"),
            "--aspnet-adapter",
        ], cwd=ROOT.parent, capture_output=True, text=True, check=True)
        value = json.loads(result.stdout)
        self.assertEqual("", result.stderr)
        self.assertEqual([700003], value["notObservedBuildIds"])
        self.assertEqual([700001, 700002, 700003], value["requiresVerificationBuildIds"])


if __name__ == "__main__":
    unittest.main()
