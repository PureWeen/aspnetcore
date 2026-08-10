#!/usr/bin/env python3

"""Aggregate reviewer eval scores without rewarding correlated duplicates."""

import argparse
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


def mean(values: Iterable[float]) -> float:
    materialized = list(values)
    return statistics.fmean(materialized) if materialized else 0.0


def macro_average(evals: list[dict[str, Any]], scores: dict[str, float], field: str) -> float:
    grouped: dict[str, list[float]] = defaultdict(list)
    for eval_data in evals:
        metadata = eval_data["eval_metadata"]
        if field == "provenance":
            provenance = metadata["provenance"]
            key = f"{provenance['kind']}:{provenance['source']}"
        else:
            key = metadata[field]
        grouped[key].append(scores[str(eval_data["id"])])
    return mean(mean(group_scores) for group_scores in grouped.values())


def aggregate_document(
    document: dict[str, Any], score_document: dict[str, Any]
) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    evals = document.get("evals", [])
    scores: dict[str, float] = {}
    expected_ids = {str(eval_data["id"]) for eval_data in evals}

    for identifier, value in score_document.items():
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            errors.append(f"score for eval {identifier} must be numeric")
        elif not 0 <= value <= 1:
            errors.append(f"score for eval {identifier} must be between 0 and 1")
        else:
            scores[str(identifier)] = float(value)

    missing = sorted(expected_ids - set(scores))
    extra = sorted(set(scores) - expected_ids)
    if missing:
        errors.append(f"missing eval scores: {', '.join(missing)}")
    if extra:
        errors.append(f"unknown eval scores: {', '.join(extra)}")
    if errors:
        return {}, errors

    tiers: dict[str, Any] = {}
    for tier in ("train", "held_out"):
        tier_evals = [
            eval_data
            for eval_data in evals
            if eval_data["eval_metadata"]["tier"] == tier
        ]
        if not tier_evals:
            continue
        tiers[tier] = {
            "eval_count": len(tier_evals),
            "raw_mean": mean(scores[str(eval_data["id"])] for eval_data in tier_evals),
            "family_macro": macro_average(
                tier_evals, scores, "score_family"
            ),
            "provenance_macro": macro_average(
                tier_evals, scores, "provenance"
            ),
        }

    train = tiers.get("train", {})
    held_out = tiers.get("held_out", {})
    return {
        "raw_mean": mean(scores.values()),
        "tiers": tiers,
        "transfer_gap": {
            "family_macro": (
                train["family_macro"] - held_out["family_macro"]
                if train and held_out
                else None
            ),
            "provenance_macro": (
                train["provenance_macro"] - held_out["provenance_macro"]
                if train and held_out
                else None
            ),
        },
    }, []


def parse_vally_results(
    result_paths: list[Path],
    expected_skill_name: str | None = None,
) -> tuple[dict[str, float], list[str]]:
    scores: dict[str, list[float]] = defaultdict(list)
    expected_run_counts: dict[str, int] = {}
    trajectory_states: dict[str, str] = {}
    grader_error_sources: dict[str, str] = {}
    errors: list[str] = []

    for result_path in result_paths:
        try:
            lines = result_path.read_text(encoding="utf-8").splitlines()
        except OSError as error:
            errors.append(f"{result_path}: unable to read Vally results: {error}")
            continue

        for line_number, line in enumerate(lines, start=1):
            if not line.strip():
                continue
            try:
                outcome = json.loads(line)
            except json.JSONDecodeError as error:
                errors.append(
                    f"{result_path}:{line_number}: invalid JSON: {error}"
                )
                continue
            if outcome.get("type") == "run-summary":
                continue

            grade_result = outcome.get("gradeResult")
            trajectory = outcome.get("trajectory")
            stimulus_name = (
                grade_result.get("stimulusName")
                if isinstance(grade_result, dict)
                else None
            )
            if not isinstance(stimulus_name, str):
                top_level_stimulus = outcome.get("stimulus")
                if isinstance(top_level_stimulus, str):
                    stimulus_name = top_level_stimulus

            stimulus = (
                trajectory.get("stimulus")
                if isinstance(trajectory, dict)
                else None
            )
            if not isinstance(stimulus_name, str) and isinstance(stimulus, dict):
                stimulus_name = stimulus.get("name")

            if not isinstance(stimulus_name, str):
                errors.append(
                    f"{result_path}:{line_number}: missing stimulus name"
                )
                continue
            match = re.fullmatch(r"eval-(\d+)(?:-.+)?", stimulus_name)
            if match is None:
                errors.append(
                    f"{result_path}:{line_number}: unsupported stimulus name "
                    f"{stimulus_name!r}"
                )
                continue
            identifier = str(int(match.group(1)))

            if outcome.get("status") != "success":
                errors.append(
                    f"{result_path}:{line_number}: {stimulus_name} did not "
                    f"complete successfully: {outcome.get('error', 'unknown error')}"
                )
                continue
            if not isinstance(trajectory, dict):
                errors.append(
                    f"{result_path}:{line_number}: {stimulus_name} is missing "
                    "its successful trajectory"
                )
                continue
            trajectory_id = trajectory.get("id")
            if not isinstance(trajectory_id, str) or not trajectory_id:
                errors.append(
                    f"{result_path}:{line_number}: missing trajectory id"
                )
                continue
            tags = stimulus.get("tags") if isinstance(stimulus, dict) else None
            if expected_skill_name is not None and not isinstance(tags, dict):
                errors.append(
                    f"{result_path}:{line_number}: {stimulus_name} is missing "
                    "Vally governance tags"
                )
                continue
            if isinstance(tags, dict):
                expected_runs = tags.get("expected_runs")
                expected_model = tags.get("executor_model")
                tagged_skill = tags.get("skill_name")
                if expected_skill_name is not None and (
                    not isinstance(expected_runs, str)
                    or not expected_runs.isdigit()
                    or int(expected_runs) <= 0
                    or not isinstance(expected_model, str)
                    or not expected_model
                    or not isinstance(tagged_skill, str)
                    or not tagged_skill
                ):
                    errors.append(
                        f"{result_path}:{line_number}: {stimulus_name} has "
                        "missing or invalid Vally governance tags"
                    )
                    continue
                if isinstance(expected_runs, str) and expected_runs.isdigit():
                    run_count = int(expected_runs)
                    prior_count = expected_run_counts.setdefault(
                        identifier, run_count
                    )
                    if prior_count != run_count:
                        errors.append(
                            f"{result_path}:{line_number}: {stimulus_name} has "
                            "inconsistent expected_runs tags"
                        )
                        continue

                metadata = trajectory.get("metadata")
                actual_model = (
                    metadata.get("model")
                    if isinstance(metadata, dict)
                    else None
                )
                if (
                    isinstance(expected_model, str)
                    and actual_model != expected_model
                ):
                    errors.append(
                        f"{result_path}:{line_number}: {stimulus_name} ran with "
                        f"model {actual_model!r}; expected {expected_model!r}"
                    )
                    continue

                if (
                    expected_skill_name is not None
                    and tagged_skill != expected_skill_name
                ):
                    errors.append(
                        f"{result_path}:{line_number}: {stimulus_name} is tagged "
                        f"for skill {tagged_skill!r}; expected "
                        f"{expected_skill_name!r}"
                    )
                    continue

            if expected_skill_name is not None:
                metadata = trajectory.get("metadata")
                loaded_skills = (
                    metadata.get("skillsLoaded")
                    if isinstance(metadata, dict)
                    else None
                )
                if (
                    not isinstance(loaded_skills, list)
                    or expected_skill_name not in loaded_skills
                ):
                    errors.append(
                        f"{result_path}:{line_number}: {stimulus_name} did not "
                        f"load skill {expected_skill_name!r}"
                    )
                    continue

            if not isinstance(grade_result, dict):
                errors.append(
                    f"{result_path}:{line_number}: {stimulus_name} has no grade"
                )
                continue
            prior_state = trajectory_states.get(trajectory_id)
            if grader_has_error(grade_result):
                if prior_state is not None:
                    errors.append(
                        f"{result_path}:{line_number}: duplicate trajectory id "
                        f"{trajectory_id!r}"
                    )
                    continue
                trajectory_states[trajectory_id] = "grader-error"
                grader_error_sources[trajectory_id] = (
                    f"{result_path}:{line_number}: {stimulus_name}"
                )
                continue
            if prior_state == "success":
                errors.append(
                    f"{result_path}:{line_number}: duplicate trajectory id "
                    f"{trajectory_id!r}"
                )
                continue
            if prior_state == "grader-error":
                grader_error_sources.pop(trajectory_id, None)
            trajectory_states[trajectory_id] = "success"

            score = grade_result.get("score")
            if (
                not isinstance(score, (int, float))
                or isinstance(score, bool)
                or not 0 <= score <= 1
            ):
                errors.append(
                    f"{result_path}:{line_number}: {stimulus_name} has invalid "
                    f"score {score!r}"
                )
                continue
            scores[identifier].append(float(score))

    for source in grader_error_sources.values():
        errors.append(f"{source} contains a grader infrastructure error")

    for identifier, expected_count in expected_run_counts.items():
        actual_count = len(scores.get(identifier, []))
        if actual_count != expected_count:
            errors.append(
                f"eval {identifier} has {actual_count} completed trials; "
                f"expected {expected_count}"
            )

    if errors:
        return {}, errors

    return {
        identifier: mean(trial_scores)
        for identifier, trial_scores in scores.items()
    }, errors


def grader_has_error(result: Any) -> bool:
    if not isinstance(result, dict):
        return False
    metadata = result.get("metadata")
    if isinstance(metadata, dict) and metadata.get("error"):
        return True
    details = result.get("details")
    return isinstance(details, list) and any(
        grader_has_error(detail) for detail in details
    )


def parse_vally_result_arguments(
    arguments: list[str],
) -> tuple[dict[str, list[Path]], list[str]]:
    result_paths: dict[str, list[Path]] = defaultdict(list)
    errors: list[str] = []
    for argument in arguments:
        skill_name, separator, path_text = argument.partition("=")
        if not separator or not skill_name or not path_text:
            errors.append(
                f"invalid --vally-results value {argument!r}; "
                "expected SKILL_NAME=RESULTS_JSONL"
            )
            continue
        result_paths[skill_name].append(Path(path_text))
    return result_paths, errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Macro-aggregate ASP.NET Core reviewer eval scores."
    )
    parser.add_argument("eval_files", nargs="+", type=Path)
    score_source = parser.add_mutually_exclusive_group(required=True)
    score_source.add_argument(
        "--scores",
        type=Path,
        help="JSON object keyed by skill_name, then eval id, with scores from 0 to 1",
    )
    score_source.add_argument(
        "--vally-results",
        action="append",
        metavar="SKILL_NAME=RESULTS_JSONL",
        help=(
            "Vally JSONL results for a skill; repeat for multiple files or skills"
        ),
    )
    args = parser.parse_args()

    score_data: dict[str, Any]
    if args.scores is not None:
        try:
            score_data = json.loads(args.scores.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"ERROR: unable to read scores: {error}", file=sys.stderr)
            return 1
    else:
        score_data = {}
        result_paths, argument_errors = parse_vally_result_arguments(
            args.vally_results
        )
        if argument_errors:
            for error in argument_errors:
                print(f"ERROR: {error}", file=sys.stderr)
            return 1
        for skill_name, paths in result_paths.items():
            scores, score_errors = parse_vally_results(
                paths,
                expected_skill_name=skill_name,
            )
            if score_errors:
                for error in score_errors:
                    print(f"ERROR: {error}", file=sys.stderr)
                return 1
            score_data[skill_name] = scores

    result: dict[str, Any] = {}
    errors: list[str] = []
    for eval_path in args.eval_files:
        try:
            document = json.loads(eval_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f"{eval_path}: unable to read evals: {error}")
            continue
        skill_name = document.get("skill_name")
        if not isinstance(skill_name, str) or not skill_name:
            errors.append(f"{eval_path}: skill_name must be a nonempty string")
            continue
        skill_scores = score_data.get(skill_name)
        if not isinstance(skill_scores, dict):
            errors.append(f"{skill_name}: scores must be an object keyed by eval id")
            continue
        aggregate, aggregate_errors = aggregate_document(document, skill_scores)
        errors.extend(f"{skill_name}: {error}" for error in aggregate_errors)
        if not aggregate_errors:
            result[skill_name] = aggregate

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
