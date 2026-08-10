import tempfile
import unittest
from pathlib import Path

from sync_vally_evals import (
    MAIN_OUTPUTS,
    MODEL_GUARDRAIL_MECHANISM,
    MODEL_GUARDRAIL_OUTPUT,
    REVIEWER_EVALS,
    TRY_FIX_EVALS,
    STAGED_SKILL_FILES,
    check_outputs,
    expected_outputs,
    load_document,
    stage_skills,
)


class SyncVallyEvalsTests(unittest.TestCase):
    def test_checked_in_vally_specs_are_synchronized(self):
        self.assertEqual([], check_outputs(expected_outputs()))

    def test_every_governance_eval_has_one_vally_stimulus(self):
        outputs = expected_outputs()
        reviewer = load_document(REVIEWER_EVALS)
        try_fix = load_document(TRY_FIX_EVALS)
        reviewer_output = (
            outputs[MAIN_OUTPUTS["aspnetcore-pr-review"]]
            + outputs[MODEL_GUARDRAIL_OUTPUT]
        )
        try_fix_output = outputs[MAIN_OUTPUTS["aspnetcore-try-fix"]]

        for eval_data in reviewer["evals"]:
            marker = f'eval-{eval_data["id"]:02d}-'
            self.assertEqual(
                1,
                reviewer_output.count(f'name: "{marker}'),
            )
        for eval_data in try_fix["evals"]:
            marker = f'eval-{eval_data["id"]:02d}-'
            self.assertEqual(
                1,
                try_fix_output.count(f'name: "{marker}'),
            )

    def test_model_guardrail_runs_under_anthropic_model(self):
        outputs = expected_outputs()
        guardrail = outputs[MODEL_GUARDRAIL_OUTPUT]
        reviewer = load_document(REVIEWER_EVALS)
        guardrail_eval = next(
            eval_data
            for eval_data in reviewer["evals"]
            if eval_data["eval_metadata"]["mechanism"]
            == MODEL_GUARDRAIL_MECHANISM
        )

        self.assertIn("model: claude-sonnet-5", guardrail)
        self.assertIn(
            f'eval-{guardrail_eval["id"]:02d}-',
            guardrail,
        )
        self.assertNotIn(
            f'eval-{guardrail_eval["id"]:02d}-',
            next(
                content
                for path, content in outputs.items()
                if path.name == "regression.vally.yaml"
                and "aspnetcore-pr-review" in path.parts
            ),
        )

    def test_fixtures_use_neutral_workspace_aliases(self):
        outputs = expected_outputs()
        combined = "\n".join(outputs.values())
        reviewer = load_document(REVIEWER_EVALS)

        for eval_data in reviewer["evals"]:
            for index, file_path in enumerate(eval_data["files"], start=1):
                self.assertIn(f'src: "../../../{file_path}"', combined)
                self.assertIn(
                    f'dest: "eval-input/fixture-{index}.md"',
                    combined,
                )
                self.assertNotIn(f"- {file_path}", combined)

    def test_specs_pin_executor_model_trial_count_and_grader_threshold(self):
        for content in expected_outputs().values():
            self.assertIn('executor_model: "', content)
            self.assertIn('expected_runs: "5"', content)
            self.assertIn("          threshold: 0.7", content)

    def test_specs_use_minimal_git_repository(self):
        for content in expected_outputs().values():
            self.assertNotIn("type: worktree", content)
            self.assertNotIn("\nconfig:", content)
            self.assertIn(
                "git remote add origin "
                "https://github.com/dotnet/aspnetcore.git",
                content,
            )
            self.assertIn("commit --quiet --allow-empty", content)

    def test_staged_skills_contain_only_runtime_files(self):
        with tempfile.TemporaryDirectory() as directory:
            staging_root = Path(directory)
            stage_skills(staging_root)

            actual_files = {
                path.relative_to(staging_root / skill_name)
                for skill_name in STAGED_SKILL_FILES
                for path in (staging_root / skill_name).rglob("*")
                if path.is_file()
            }
            expected_files = {
                relative_path
                for paths in STAGED_SKILL_FILES.values()
                for relative_path in paths
            }

            self.assertEqual(expected_files, actual_files)
            self.assertFalse(
                any(path.name == "evals.json" for path in staging_root.rglob("*"))
            )

    def test_staging_rejects_repository_root(self):
        with self.assertRaises(ValueError):
            stage_skills(REVIEWER_EVALS.parents[4])
        with self.assertRaises(ValueError):
            stage_skills(REVIEWER_EVALS.parents[4] / "artifacts")


if __name__ == "__main__":
    unittest.main()
