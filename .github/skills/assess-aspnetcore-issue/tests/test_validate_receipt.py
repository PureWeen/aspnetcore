import copy
import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "validate_receipt",
    ROOT / "scripts" / "validate_receipt.py",
)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class ValidateReceiptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture = Path(__file__).parent / "fixtures" / "ready.json"
        cls.ready = json.loads(fixture.read_text(encoding="utf-8"))

    def test_ready_receipt_is_valid(self):
        self.assertEqual([], VALIDATOR.validate_receipt(self.ready))

    def test_precedence_rejects_ready_when_duplicate_is_verified(self):
        receipt = copy.deepcopy(self.ready)
        receipt["decision_signals"]["verified_duplicate"] = True

        errors = VALIDATOR.validate_receipt(receipt)

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

        errors = VALIDATOR.validate_receipt(receipt)

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

        self.assertEqual([], VALIDATOR.validate_receipt(receipt))

    def test_mutation_attestation_is_enforced(self):
        receipt = copy.deepcopy(self.ready)
        receipt["safety"]["github_mutations"] = ["commented"]

        errors = VALIDATOR.validate_receipt(receipt)

        self.assertTrue(any("github_mutations" in error for error in errors))

    def test_mutating_command_contradicts_read_only_attestation(self):
        receipt = copy.deepcopy(self.ready)
        receipt["commands"][0]["command"] = "gh issue close 1 --repo dotnet/aspnetcore"

        errors = VALIDATOR.validate_receipt(receipt)

        self.assertTrue(any("read-only safety contract" in error for error in errors))

    def test_artifact_paths_cannot_escape_root(self):
        receipt = copy.deepcopy(self.ready)
        receipt["evidence"][0]["path"] = "../issue.json"

        errors = VALIDATOR.validate_receipt(receipt)

        self.assertTrue(any("artifact-root-relative" in error for error in errors))

    def test_windows_artifact_paths_cannot_escape_root(self):
        receipt = copy.deepcopy(self.ready)
        receipt["evidence"][0]["path"] = r"..\issue.json"

        errors = VALIDATOR.validate_receipt(receipt)

        self.assertTrue(any("artifact-root-relative" in error for error in errors))

    def test_structural_failure_can_be_ready_when_runtime_is_not_feasible(self):
        receipt = copy.deepcopy(self.ready)
        receipt["investigation"]["runtime_evidence_feasible"] = False
        receipt["decision_signals"]["runtime_reproduced"] = False
        receipt["decision_signals"]["runtime_attempted"] = False
        receipt["decision_signals"]["structural_failure_verified"] = True
        receipt["reason_code"] = "structural_failure_verified"
        receipt["checks"][1]["category"] = "in_tree"
        receipt["checks"][1]["details"] = "A compiler diagnostic directly verifies the failure."
        receipt["safety"]["reproduction_isolation"] = "not_applicable"
        receipt["safety"]["credentials_removed"] = False
        receipt["safety"]["network_access"] = "not_applicable"
        receipt["safety"]["writable_roots"] = []

        self.assertEqual([], VALIDATOR.validate_receipt(receipt))

    def test_schema_rejects_invalid_timestamp_and_nested_property(self):
        receipt = copy.deepcopy(self.ready)
        receipt["generated_at"] = "not-a-date"
        receipt["issue"]["unexpected"] = True

        errors = VALIDATOR.validate_receipt(receipt)

        self.assertTrue(any("date-time" in error for error in errors))
        self.assertTrue(any("unexpected" in error for error in errors))

    def test_ready_reproduction_requires_successful_command_output(self):
        receipt = copy.deepcopy(self.ready)
        receipt["checks"][1]["command_ids"] = []
        receipt["checks"][1]["evidence_refs"] = ["issue-snapshot"]

        errors = VALIDATOR.validate_receipt(receipt)

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
        receipt["safety"]["credentials_removed"] = False
        receipt["safety"]["network_access"] = "not_applicable"
        receipt["safety"]["writable_roots"] = []

        errors = VALIDATOR.validate_receipt(receipt)

        self.assertTrue(any("winning decision row" in error for error in errors))

    def test_runtime_attempt_requires_isolation_attestation(self):
        receipt = copy.deepcopy(self.ready)
        receipt["safety"]["credentials_removed"] = False

        errors = VALIDATOR.validate_receipt(receipt)

        self.assertIn("runtime attempts require credentials_removed", errors)

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
        receipt["safety"]["credentials_removed"] = False
        receipt["safety"]["network_access"] = "not_applicable"
        receipt["safety"]["writable_roots"] = []

        errors = VALIDATOR.validate_receipt(receipt)

        self.assertTrue(any("decisive check with evidence" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
