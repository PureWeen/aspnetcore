import copy
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import receipt
from contract import PROFILES, commands


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.target = {"head": "a" * 40, "mergeBase": "b" * 40, "baseTip": "c" * 40}
        self.identity = {
            "repository": "PureWeen/aspnetcore", "pr": "42", "workflow_sha": "d" * 40,
            "run_id": "123", "run_attempt": "1",
        }
        self.hashes = {key + "_sha256": "e" * 64 for key in ("launcher", "guest", "contract")}
        self.report = {
            "schema": 2, "repository": self.identity["repository"], "pull_request": "42",
            "workflow_repository": self.identity["repository"], "workflow_sha": "d" * 40,
            "implementation_sha": "d" * 40, "run_id": "123", "run_attempt": "1",
            "head_sha": self.target["head"], "merge_base": self.target["mergeBase"],
            "base_tip": self.target["baseTip"], **self.hashes,
            "status": "passed", "profile": PROFILES[0], "sdk": "11.0.100-rc.1.26420.103",
            "acceptance": dict.fromkeys(receipt.ACCEPTANCE, True),
            "tests": {"executed": 110, "passed": 110, "failed": 0, "skipped": 0},
            "phases": [
                {"name": name, "command": command, "exit": 0, "seconds": 1.25}
                for name, command in commands(PROFILES[0]).items()
            ],
            "uncovered_changed_paths": ["docs/example.md"],
        }

    def normalize(self, report):
        return receipt.normalize(report, self.target, self.identity, self.hashes)

    def test_passed_suite_is_head_only_supporting_evidence(self):
        result = self.normalize(self.report)
        self.assertTrue(result["available"])
        self.assertEqual("head-green", result["classification"])
        self.assertTrue(result["supportingEvidenceOnly"])
        self.assertEqual({"executed": 110, "passed": 110, "failed": 0, "skipped": 0}, result["counts"])
        self.assertEqual(1, result["uncoveredChangedPathCount"])
        self.assertEqual(self.report["phases"], result["phases"])

    def test_every_identity_and_helper_hash_is_bound(self):
        for field in (
            "repository", "workflow_repository", "pull_request", "head_sha", "merge_base", "base_tip",
            "workflow_sha", "implementation_sha", "run_id", "run_attempt",
            "launcher_sha256", "guest_sha256", "contract_sha256",
        ):
            with self.subTest(field=field):
                report = {**self.report, field: "mismatch"}
                self.assertFalse(self.normalize(report)["available"])

    def test_schema_and_identity_types_are_not_coerced(self):
        for field, value in (("schema", True), ("schema", 2.0), ("pull_request", 42), ("run_attempt", 1)):
            with self.subTest(field=field):
                self.assertFalse(self.normalize({**self.report, field: value})["available"])

    def test_zero_skipped_failed_and_contradictory_counts_are_not_green(self):
        cases = {
            "zero": {"executed": 0, "passed": 0, "failed": 0, "skipped": 0},
            "all-skipped": {"executed": 0, "passed": 0, "failed": 0, "skipped": 110},
            "failed": {"executed": 110, "passed": 109, "failed": 1, "skipped": 0},
            "contradiction": {"executed": 110, "passed": 109, "failed": 0, "skipped": 0},
            "boolean": {"executed": True, "passed": True, "failed": 0, "skipped": 0},
            "negative": {"executed": -1, "passed": -1, "failed": 0, "skipped": 0},
            "oversized": {"executed": 100001, "passed": 100001, "failed": 0, "skipped": 0},
        }
        for name, counts in cases.items():
            with self.subTest(case=name):
                self.assertFalse(self.normalize({**self.report, "tests": counts})["available"])

    def test_every_acceptance_gate_must_be_true(self):
        for field in receipt.ACCEPTANCE:
            with self.subTest(gate=field):
                report = copy.deepcopy(self.report)
                report["acceptance"][field] = False
                self.assertFalse(self.normalize(report)["available"])

    def test_incomplete_or_changed_phase_contract_is_not_green(self):
        for name, change in (
            ("missing", lambda phases: phases.pop()),
            ("command", lambda phases: phases[2]["command"].append("untrusted argument")),
            ("exit", lambda phases: phases[2].update(exit=1)),
            ("negative-time", lambda phases: phases[2].update(seconds=-1)),
            ("nonfinite-time", lambda phases: phases[2].update(seconds=math.nan)),
            ("reordered", lambda phases: phases.reverse()),
        ):
            with self.subTest(case=name):
                report = copy.deepcopy(self.report)
                change(report["phases"])
                self.assertFalse(self.normalize(report)["available"])

    def test_unknown_profile_or_sdk_is_not_green(self):
        for field, value in (("profile", {"id": "arbitrary"}), ("sdk", "untrusted\ninstructions")):
            with self.subTest(field=field):
                self.assertFalse(self.normalize({**self.report, field: value})["available"])

    def test_untrusted_extra_output_is_not_forwarded(self):
        report = {**self.report, "stdout": "untrusted output", "reason": "untrusted reason"}
        result = self.normalize(report)
        self.assertNotIn("untrusted", json.dumps(result))
        failed = self.normalize({**report, "status": "failed"})
        self.assertFalse(failed["available"])
        self.assertEqual("unavailable", failed["classification"])
        self.assertNotIn("untrusted", json.dumps(failed))

    def test_unsupported_is_explicit_not_green(self):
        result = self.normalize({**self.report, "status": "unsupported"})
        self.assertFalse(result["available"])
        self.assertEqual("unsupported", result["classification"])
        receipt.verify_files({"status": "unsupported", "file_sha256": {}}, Path("."))

    def test_file_inventory_missing_and_tampered_results_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "test.log"
            path.write_bytes(b"original")
            report = {"status": "failed", "file_sha256": {
                "test.log": hashlib.sha256(path.read_bytes()).hexdigest(),
            }}
            receipt.verify_files(report, root)
            path.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "hash or bounds"):
                receipt.verify_files(report, root)
            with self.assertRaisesRegex(ValueError, "inventory"):
                receipt.verify_files({"file_sha256": {"../test.log": "e" * 64}}, root)
            with self.assertRaisesRegex(ValueError, "missing"):
                receipt.verify_files({"status": "passed", "file_sha256": {}}, root)

    def test_export_round_trip_preserves_counts_and_verbatim_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = copy.deepcopy(self.report)
            report["file_sha256"] = {}
            for name in receipt.FILES - {"failure.txt"}:
                path = root / name
                path.write_bytes(b"retained evidence")
                report["file_sha256"][name] = hashlib.sha256(path.read_bytes()).hexdigest()
            for key, filename in (("launcher", "host.py"), ("guest", "guest.py"), ("contract", "contract.py")):
                report[key + "_sha256"] = hashlib.sha256(Path(receipt.__file__).with_name(filename).read_bytes()).hexdigest()
            (root / "receipt.json").write_text(json.dumps(report), encoding="utf-8")
            (root / "manifest.json").write_text(json.dumps({"target": self.target}), encoding="utf-8")
            environment = {
                "GITHUB_REPOSITORY": self.identity["repository"], "REVIEW_PR": "42",
                "GITHUB_WORKFLOW_SHA": self.identity["workflow_sha"], "GITHUB_RUN_ID": "123",
                "GITHUB_RUN_ATTEMPT": "1",
                "REVIEW_EXECUTION_RUN_URL": "https://github.com/PureWeen/aspnetcore/actions/runs/123",
            }
            arguments = ["receipt.py", str(root / "receipt.json"), str(root / "manifest.json"), str(root / "execution.json")]
            with patch.dict(os.environ, environment), patch.object(sys, "argv", arguments):
                receipt.main()
            exported = json.loads((root / "execution.json").read_text(encoding="utf-8"))
            self.assertTrue(exported["available"])
            self.assertEqual(report["tests"], exported["counts"])
            self.assertEqual(report["phases"], exported["phases"])
            summary = (root / "execution-public-summary.txt").read_text(encoding="utf-8")
            self.assertEqual(exported["publicSummary"], summary)
            self.assertIn("No baseline, product reversion, browser workflow, or newly authored repro", summary)
            self.assertLessEqual(len(summary), 2400)


if __name__ == "__main__":
    unittest.main()
