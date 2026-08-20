import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR_SPEC = importlib.util.spec_from_file_location(
    "validate_readiness_receipt",
    ROOT / "scripts" / "validate_readiness_receipt.py",
)
VALIDATOR = importlib.util.module_from_spec(VALIDATOR_SPEC)
VALIDATOR_SPEC.loader.exec_module(VALIDATOR)
ACQUISITION_SPEC = importlib.util.spec_from_file_location(
    "acquire_public_issue_snapshot",
    ROOT / "scripts" / "acquire_public_issue_snapshot.py",
)
ACQUISITION = importlib.util.module_from_spec(ACQUISITION_SPEC)
ACQUISITION_SPEC.loader.exec_module(ACQUISITION)


class FakeResponse:
    def __init__(self, value):
        self._content = json.dumps(value).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self):
        return self._content


class ValidateReadinessReceiptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture = Path(__file__).parent / "fixtures" / "ready-for-fix-investigation.json"
        cls.ready = json.loads(fixture.read_text(encoding="utf-8"))

    def test_ready_receipt_is_valid(self):
        self.assertEqual([], VALIDATOR.validate_readiness_receipt(self.ready))

    def test_precedence_rejects_ready_when_duplicate_is_verified(self):
        receipt = copy.deepcopy(self.ready)
        receipt["decision_signals"]["verified_duplicate"] = True

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("violates precedence" in error for error in errors))

    def test_source_only_ready_is_rejected_when_runtime_evidence_is_feasible(self):
        receipt = copy.deepcopy(self.ready)
        receipt["checks"][1]["status"] = "skipped"
        receipt["checks"][1]["evidence_refs"] = []
        receipt["check_summary"] = {
            "attempted": 1,
            "passed": 1,
            "failed": 0,
            "skipped": 1,
            "blocked": 0,
        }

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("passed reproduction check" in error for error in errors))

    def test_not_reproduced_routes_to_recheck(self):
        receipt = copy.deepcopy(self.ready)
        receipt["decision_signals"]["runtime_reproduced"] = False
        receipt["primary_disposition"] = "not_reproduced"
        receipt["reason_code"] = "bounded_repro_did_not_reproduce"
        receipt["next_route"] = "maintainer_recheck_or_reporter_evidence"
        receipt["checks"][1]["status"] = "failed"
        receipt["check_summary"] = {
            "attempted": 2,
            "passed": 1,
            "failed": 1,
            "skipped": 0,
            "blocked": 0,
        }

        self.assertEqual([], VALIDATOR.validate_readiness_receipt(receipt))

    def test_mutation_attestation_is_enforced(self):
        receipt = copy.deepcopy(self.ready)
        receipt["safety"]["github_mutations"] = ["commented"]

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("github_mutations" in error for error in errors))

    def test_mutating_command_contradicts_read_only_attestation(self):
        receipt = copy.deepcopy(self.ready)
        receipt["commands"][0]["command"] = "gh issue close 1 --repo dotnet/aspnetcore"

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("read-only safety attestation" in error for error in errors))

    def test_implicit_curl_upload_contradicts_read_only_attestation(self):
        receipt = copy.deepcopy(self.ready)
        receipt["commands"][0]["command"] = (
            "curl --data x "
            "https://api.github.com/repos/dotnet/aspnetcore/issues/1/comments"
        )

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("read-only safety attestation" in error for error in errors))

    def test_artifact_paths_cannot_escape_root(self):
        receipt = copy.deepcopy(self.ready)
        receipt["evidence"][0]["path"] = "../issue.json"

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("artifact-root-relative" in error for error in errors))

    def test_windows_artifact_paths_cannot_escape_root(self):
        receipt = copy.deepcopy(self.ready)
        receipt["evidence"][0]["path"] = r"..\issue.json"

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("artifact-root-relative" in error for error in errors))

    def test_structural_failure_can_be_ready_when_runtime_is_not_feasible(self):
        receipt = copy.deepcopy(self.ready)
        receipt["investigation"]["runtime_evidence_feasible"] = False
        receipt["decision_signals"]["runtime_reproduced"] = False
        receipt["decision_signals"]["runtime_attempted"] = True
        receipt["decision_signals"]["structural_failure_verified"] = True
        receipt["reason_code"] = "structural_failure_verified"
        receipt["checks"][1]["category"] = "in_tree"
        receipt["checks"][1]["details"] = "A compiler diagnostic directly verifies the failure."

        self.assertEqual([], VALIDATOR.validate_readiness_receipt(receipt))

    def test_schema_rejects_invalid_timestamp_and_nested_property(self):
        receipt = copy.deepcopy(self.ready)
        receipt["generated_at"] = "not-a-date"
        receipt["issue"]["unexpected"] = True

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("date-time" in error for error in errors))
        self.assertTrue(any("unexpected" in error for error in errors))

    def test_ready_reproduction_requires_successful_command_output(self):
        receipt = copy.deepcopy(self.ready)
        receipt["checks"][1]["command_ids"] = []
        receipt["checks"][1]["evidence_refs"] = ["issue-snapshot"]

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("passed reproduction check" in error for error in errors))

    def test_fallback_decision_requires_fallback_reason_and_route(self):
        receipt = copy.deepcopy(self.ready)
        receipt["decision_signals"]["runtime_reproduced"] = False
        receipt["decision_signals"]["runtime_attempted"] = False
        receipt["primary_disposition"] = "infrastructure_blocked_or_inconclusive"
        receipt["reason_code"] = "environment_blocked"
        receipt["next_route"] = "infrastructure_or_retry"
        receipt["checks"][1]["status"] = "skipped"
        receipt["check_summary"] = {
            "attempted": 1,
            "passed": 1,
            "failed": 0,
            "skipped": 1,
            "blocked": 0,
        }
        receipt["safety"]["reproduction_isolation"] = "not_applicable"

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("winning decision row" in error for error in errors))

    def test_runtime_attempt_requires_isolation_attestation(self):
        receipt = copy.deepcopy(self.ready)
        receipt["safety"]["credentials_removed"] = False

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertIn("runtime attempts require credentials_removed", errors)

    def test_recorded_runtime_execution_cannot_hide_behind_false_signal(self):
        receipt = copy.deepcopy(self.ready)
        receipt["decision_signals"]["runtime_attempted"] = False
        receipt["safety"]["reproduction_isolation"] = "not_applicable"
        receipt["commands"][0]["working_directory"] = receipt["assessed_repository"]["path"]

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertIn(
            "recorded reproduction or in-tree execution requires runtime_attempted",
            errors,
        )
        self.assertTrue(any("must not run in the user's source worktree" in error for error in errors))

    def test_verified_duplicate_requires_decisive_evidence(self):
        receipt = copy.deepcopy(self.ready)
        receipt["decision_signals"]["runtime_reproduced"] = False
        receipt["decision_signals"]["runtime_attempted"] = False
        receipt["decision_signals"]["verified_duplicate"] = True
        receipt["primary_disposition"] = "duplicate_or_already_fixed"
        receipt["reason_code"] = "duplicate_verified"
        receipt["next_route"] = "existing_issue_or_release"
        receipt["checks"][0]["evidence_refs"] = []
        receipt["checks"][1]["status"] = "skipped"
        receipt["checks"][1]["evidence_refs"] = []
        receipt["check_summary"] = {
            "attempted": 1,
            "passed": 1,
            "failed": 0,
            "skipped": 1,
            "blocked": 0,
        }
        receipt["safety"]["reproduction_isolation"] = "not_applicable"

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("decisive check with evidence" in error for error in errors))

    def test_verified_duplicate_requires_resolution_reference(self):
        receipt = copy.deepcopy(self.ready)
        receipt["decision_signals"]["runtime_reproduced"] = False
        receipt["decision_signals"]["runtime_attempted"] = False
        receipt["decision_signals"]["verified_duplicate"] = True
        receipt["primary_disposition"] = "duplicate_or_already_fixed"
        receipt["reason_code"] = "duplicate_verified"
        receipt["next_route"] = "existing_issue_or_release"
        receipt["checks"][1]["status"] = "skipped"
        receipt["check_summary"] = {
            "attempted": 1,
            "passed": 1,
            "failed": 0,
            "skipped": 1,
            "blocked": 0,
        }
        receipt["safety"]["reproduction_isolation"] = "not_applicable"

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertIn(
            "duplicate_or_already_fixed requires a resolution_reference",
            errors,
        )

    def test_ready_uses_neutral_fix_investigation_route(self):
        self.assertEqual("fix_investigation", self.ready["next_route"])
        disposition, _, routes = VALIDATOR.expected_decision(self.ready["decision_signals"])

        self.assertEqual("ready_for_fix_investigation", disposition)
        self.assertEqual({"fix_investigation"}, routes)

    def test_public_get_snapshot_mode_is_valid(self):
        receipt = copy.deepcopy(self.ready)
        receipt["safety"]["input_mode"] = "public_get_snapshot"
        receipt["safety"]["github_access"] = "public_get_only"
        receipt["safety"]["acquisition_external_network_access"] = "public_github_get_only"

        self.assertEqual([], VALIDATOR.validate_readiness_receipt(receipt))

    def test_host_attestation_cannot_claim_hard_guarantee(self):
        receipt = copy.deepcopy(self.ready)
        receipt["safety"]["execution_boundary"] = "host_attestation"

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertIn("host_attestation cannot claim a hard no-mutation guarantee", errors)

    def test_host_attested_mode_is_valid_without_hard_guarantee(self):
        receipt = copy.deepcopy(self.ready)
        receipt["safety"]["assessment_mode"] = "host_attested"
        receipt["safety"]["execution_boundary"] = "host_attestation"
        receipt["safety"]["hard_no_mutation_guarantee"] = False

        self.assertEqual([], VALIDATOR.validate_readiness_receipt(receipt))

    def test_writable_roots_must_match_authorized_roots(self):
        receipt = copy.deepcopy(self.ready)
        receipt["safety"]["writable_roots"].append("/tmp/unrecorded")

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("writable_roots must exactly contain" in error for error in errors))

    def test_writable_roots_cannot_overlap_user_source_worktree(self):
        receipt = copy.deepcopy(self.ready)
        receipt["assessed_repository"]["path"] = receipt["artifact_root"]

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertTrue(any("must not overlap" in error for error in errors))
        self.assertTrue(any("must not run in the user's source worktree" in error for error in errors))

    def test_interactive_runtime_requires_loopback(self):
        receipt = copy.deepcopy(self.ready)
        receipt["environment"]["render_mode"] = "interactive_server"
        receipt["upstream_triage"]["labels"] = ["area-blazor"]
        receipt["investigation"]["components_validator_delegated"] = True

        errors = VALIDATOR.validate_readiness_receipt(receipt)

        self.assertIn("interactive runtime assessment requires loopback_network_access", errors)
        receipt["safety"]["loopback_network_access"] = True
        self.assertEqual([], VALIDATOR.validate_readiness_receipt(receipt))

    def test_full_evidence_file_validation_detects_tampering(self):
        receipt = copy.deepcopy(self.ready)
        with tempfile.TemporaryDirectory() as temporary_directory:
            artifact_root = Path(temporary_directory) / "readiness"
            evidence_root = artifact_root / "evidence"
            worktree_root = artifact_root / "worktree"
            cache_root = artifact_root / "cache"
            temp_root = artifact_root / "tmp"
            for path in (evidence_root, worktree_root / "repro", cache_root, temp_root):
                path.mkdir(parents=True, exist_ok=True)

            contents = {
                "issue-snapshot": b"{\"number\": 1}\n",
                "repro-output": b"reproduced\n",
            }
            for item in receipt["evidence"]:
                content = contents[item["id"]]
                (artifact_root / item["path"]).write_bytes(content)
                item["sha256"] = hashlib.sha256(content).hexdigest()

            receipt["artifact_root"] = str(artifact_root)
            receipt["commands"][0]["working_directory"] = str(worktree_root / "repro")
            receipt["safety"]["writable_roots"] = [
                str(artifact_root),
                str(worktree_root),
                str(cache_root),
                str(temp_root),
            ]
            receipt["safety"]["disposable_worktree_root"] = str(worktree_root)
            receipt["safety"]["cache_roots"] = [str(cache_root)]
            receipt["safety"]["temp_roots"] = [str(temp_root)]
            receipt_path = artifact_root / "receipt.json"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")

            self.assertEqual([], VALIDATOR.validate_readiness_receipt(receipt))
            self.assertEqual(
                [],
                VALIDATOR.validate_readiness_evidence_files(receipt, receipt_path),
            )

            (evidence_root / "repro.log").write_text("tampered\n", encoding="utf-8")
            errors = VALIDATOR.validate_readiness_evidence_files(receipt, receipt_path)
            self.assertTrue(any("SHA-256 does not match" in error for error in errors))

    def test_public_snapshot_acquisition_uses_only_unauthenticated_get(self):
        requests = []

        def opener(request, timeout):
            self.assertEqual(30, timeout)
            requests.append(request)
            if "/comments?" in request.full_url:
                return FakeResponse([])
            number = 456 if request.full_url.endswith("/456") else 123
            return FakeResponse(
                {
                    "number": number,
                    "html_url": f"https://github.com/dotnet/aspnetcore/issues/{number}",
                    "repository_url": "https://api.github.com/repos/dotnet/aspnetcore",
                }
            )

        with tempfile.TemporaryDirectory() as artifact_root:
            manifest_path = ACQUISITION.acquire_snapshot(
                123,
                Path(artifact_root),
                related_issues=[456],
                opener=opener,
            )
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        self.assertFalse(manifest["authenticated"])
        self.assertEqual("public_get_snapshot", manifest["input_mode"])
        self.assertTrue(requests)
        self.assertTrue(all(request.get_method() == "GET" for request in requests))
        self.assertTrue(all("Authorization" not in request.headers for request in requests))

    def test_public_snapshot_rejects_pull_request_as_primary_issue(self):
        def opener(request, timeout):
            return FakeResponse(
                {
                    "number": 123,
                    "html_url": "https://github.com/dotnet/aspnetcore/pull/123",
                    "repository_url": "https://api.github.com/repos/dotnet/aspnetcore",
                    "pull_request": {},
                }
            )

        with tempfile.TemporaryDirectory() as artifact_root:
            with self.assertRaisesRegex(ValueError, "pull request"):
                ACQUISITION.acquire_snapshot(123, Path(artifact_root), opener=opener)

    def test_public_snapshot_rejects_root_containing_repository(self):
        repository_root = ROOT.parents[2]

        with self.assertRaisesRegex(ValueError, "must not overlap"):
            ACQUISITION.acquire_snapshot(123, repository_root.parent)


if __name__ == "__main__":
    unittest.main()
