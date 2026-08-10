import json
import tempfile
import unittest
from pathlib import Path

from aggregate_eval_scores import (
    aggregate_document,
    parse_vally_result_arguments,
    parse_vally_results,
)


class AggregateEvalScoresTests(unittest.TestCase):
    def test_family_macro_does_not_reward_duplicate_family_cases(self):
        document = {
            "evals": [
                self.eval_data(1, "train", "family-a", "source-a"),
                self.eval_data(2, "train", "family-a", "source-a"),
                self.eval_data(3, "train", "family-b", "source-b"),
                self.eval_data(4, "held_out", "family-c", "source-c"),
            ]
        }
        result, errors = aggregate_document(
            document,
            {"1": 1.0, "2": 1.0, "3": 0.0, "4": 0.5},
        )

        self.assertEqual([], errors)
        self.assertAlmostEqual(0.5, result["tiers"]["train"]["family_macro"])
        self.assertAlmostEqual(0.5, result["tiers"]["train"]["provenance_macro"])
        self.assertAlmostEqual(2 / 3, result["tiers"]["train"]["raw_mean"])

    def test_scores_must_cover_exact_eval_ids(self):
        document = {
            "evals": [
                self.eval_data(1, "train", "family-a", "source-a"),
            ]
        }

        result, errors = aggregate_document(
            document,
            {"2": 1.0},
        )

        self.assertEqual({}, result)
        self.assertIn("missing eval scores: 1", errors)
        self.assertIn("unknown eval scores: 2", errors)

    def test_transfer_gap_is_null_without_both_tiers(self):
        document = {
            "evals": [
                self.eval_data(1, "train", "family-a", "source-a"),
            ]
        }

        result, errors = aggregate_document(document, {"1": 1.0})

        self.assertEqual([], errors)
        self.assertIsNone(result["transfer_gap"]["family_macro"])
        self.assertIsNone(result["transfer_gap"]["provenance_macro"])

    def test_vally_results_average_trials_by_eval_id(self):
        outcomes = [
            self.vally_outcome(
                "eval-01-first-case", 1.0, trajectory_id="trial-1"
            ),
            self.vally_outcome(
                "eval-01-first-case", 0.5, trajectory_id="trial-2"
            ),
            self.vally_outcome(
                "eval-02-second-case", 0.25, trajectory_id="trial-3"
            ),
            {"type": "run-summary", "passed": True, "evals": []},
        ]
        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "results.jsonl"
            result_path.write_text(
                "\n".join(json.dumps(outcome) for outcome in outcomes) + "\n",
                encoding="utf-8",
            )

            scores, errors = parse_vally_results([result_path])

        self.assertEqual([], errors)
        self.assertEqual({"1": 0.75, "2": 0.25}, scores)

    def test_vally_results_reject_failed_or_ungraded_trials(self):
        outcomes = [
            {
                "status": "error",
                "stimulus": "eval-01-first-case",
                "trajectory": None,
                "gradeResult": None,
                "error": "agent timed out",
            },
            {
                "status": "success",
                "trajectory": {
                    "id": "trial-2",
                    "stimulus": {"name": "eval-02-second-case"}
                },
                "gradeResult": None,
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "results.jsonl"
            result_path.write_text(
                "\n".join(json.dumps(outcome) for outcome in outcomes) + "\n",
                encoding="utf-8",
            )

            scores, errors = parse_vally_results([result_path])

        self.assertEqual({}, scores)
        self.assertEqual(2, len(errors))
        self.assertIn("did not complete successfully", errors[0])
        self.assertIn("has no grade", errors[1])

    def test_vally_results_reject_partial_duplicate_and_wrong_model_runs(self):
        partial = self.vally_outcome(
            "eval-01-first-case",
            1.0,
            trajectory_id="trial-1",
            expected_runs=2,
        )
        wrong_model = self.vally_outcome(
            "eval-02-second-case",
            1.0,
            trajectory_id="trial-2",
            expected_runs=1,
            model="claude-sonnet-5",
        )
        duplicate = self.vally_outcome(
            "eval-03-third-case",
            1.0,
            trajectory_id="trial-1",
            expected_runs=1,
        )
        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "results.jsonl"
            result_path.write_text(
                "\n".join(
                    json.dumps(outcome)
                    for outcome in (partial, wrong_model, duplicate)
                )
                + "\n",
                encoding="utf-8",
            )

            scores, errors = parse_vally_results(
                [result_path],
                expected_skill_name="aspnetcore-pr-review",
            )

        self.assertEqual({}, scores)
        self.assertTrue(any("expected 2" in error for error in errors))
        self.assertTrue(any("ran with model" in error for error in errors))
        self.assertTrue(any("duplicate trajectory id" in error for error in errors))

    def test_vally_results_reject_baseline_and_grader_errors(self):
        baseline = self.vally_outcome(
            "eval-01-first-case",
            1.0,
            trajectory_id="trial-1",
            expected_runs=1,
            loaded_skills=[],
        )
        grader_error = self.vally_outcome(
            "eval-02-second-case",
            0.0,
            trajectory_id="trial-2",
            expected_runs=1,
        )
        grader_error["gradeResult"]["details"] = [
            {
                "name": "prompt",
                "score": 0,
                "metadata": {"error": "judge timed out"},
            }
        ]
        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "results.jsonl"
            result_path.write_text(
                "\n".join(
                    json.dumps(outcome)
                    for outcome in (baseline, grader_error)
                )
                + "\n",
                encoding="utf-8",
            )

            scores, errors = parse_vally_results(
                [result_path],
                expected_skill_name="aspnetcore-pr-review",
            )

        self.assertEqual({}, scores)
        self.assertTrue(any("did not load skill" in error for error in errors))
        self.assertTrue(
            any("grader infrastructure error" in error for error in errors)
        )

    def test_vally_results_require_governance_tags(self):
        outcome = self.vally_outcome(
            "eval-01-first-case",
            1.0,
            trajectory_id="trial-1",
        )
        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "results.jsonl"
            result_path.write_text(
                json.dumps(outcome) + "\n",
                encoding="utf-8",
            )

            scores, errors = parse_vally_results(
                [result_path],
                expected_skill_name="aspnetcore-pr-review",
            )

        self.assertEqual({}, scores)
        self.assertTrue(
            any("Vally governance tags" in error for error in errors)
        )

    def test_regraded_record_supersedes_matching_grader_error(self):
        original = self.vally_outcome(
            "eval-01-first-case",
            0.0,
            trajectory_id="trial-1",
            expected_runs=1,
        )
        original["gradeResult"]["details"] = [
            {
                "name": "prompt",
                "score": 0,
                "metadata": {"error": "malformed judge response"},
            }
        ]
        regraded = self.vally_outcome(
            "eval-01-first-case",
            0.75,
            trajectory_id="trial-1",
            expected_runs=1,
        )
        with tempfile.TemporaryDirectory() as directory:
            original_path = Path(directory) / "original.jsonl"
            regraded_path = Path(directory) / "regraded.jsonl"
            original_path.write_text(
                json.dumps(original) + "\n",
                encoding="utf-8",
            )
            regraded_path.write_text(
                json.dumps(regraded) + "\n",
                encoding="utf-8",
            )

            scores, errors = parse_vally_results(
                [original_path, regraded_path],
                expected_skill_name="aspnetcore-pr-review",
            )

        self.assertEqual([], errors)
        self.assertEqual({"1": 0.75}, scores)

    def test_vally_result_arguments_group_multiple_files_per_skill(self):
        result, errors = parse_vally_result_arguments(
            [
                "aspnetcore-pr-review=first.jsonl",
                "aspnetcore-pr-review=second.jsonl",
                "aspnetcore-try-fix=third.jsonl",
            ]
        )

        self.assertEqual([], errors)
        self.assertEqual(
            [Path("first.jsonl"), Path("second.jsonl")],
            result["aspnetcore-pr-review"],
        )
        self.assertEqual(
            [Path("third.jsonl")],
            result["aspnetcore-try-fix"],
        )

    @staticmethod
    def vally_outcome(
        stimulus_name: str,
        score: float,
        *,
        trajectory_id: str = "trajectory",
        expected_runs: int | None = None,
        model: str = "gpt-5.6-sol",
        loaded_skills: list[str] | None = None,
    ) -> dict:
        tags = {}
        if expected_runs is not None:
            tags = {
                "expected_runs": str(expected_runs),
                "executor_model": "gpt-5.6-sol",
                "skill_name": "aspnetcore-pr-review",
            }
        return {
            "status": "success",
            "trajectory": {
                "id": trajectory_id,
                "stimulus": {"name": stimulus_name, "tags": tags},
                "metadata": {
                    "model": model,
                    "skillsLoaded": (
                        ["aspnetcore-pr-review"]
                        if loaded_skills is None
                        else loaded_skills
                    ),
                },
            },
            "gradeResult": {
                "stimulusName": stimulus_name,
                "score": score,
            },
        }

    @staticmethod
    def eval_data(
        identifier: int,
        tier: str,
        family: str,
        provenance: str,
    ) -> dict:
        return {
            "id": identifier,
            "eval_metadata": {
                "tier": tier,
                "score_family": family,
                "provenance": {
                    "kind": "synthetic",
                    "source": provenance,
                },
            },
        }


if __name__ == "__main__":
    unittest.main()
