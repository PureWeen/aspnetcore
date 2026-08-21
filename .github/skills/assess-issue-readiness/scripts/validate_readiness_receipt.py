#!/usr/bin/env python3

import argparse
import hashlib
import json
import re
import shlex
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path, PurePosixPath


SCHEMA_PATH = Path(__file__).resolve().parents[1] / "references" / "readiness-receipt.schema.json"
RECEIPT_SCHEMA = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

DISPOSITIONS = {
    "security_process_required": {
        "reasons": {"security_boundary"},
        "routes": {"security_reporting_process"},
    },
    "duplicate_or_already_fixed": {
        "reasons": {"duplicate_verified", "already_fixed_verified"},
        "routes": {"existing_issue_or_release"},
    },
    "by_design": {
        "reasons": {"upstream_by_design_verified"},
        "routes": {"stop_by_design"},
    },
    "unsupported_usage": {
        "reasons": {"unsupported_configuration_verified"},
        "routes": {"supported_usage_guidance"},
    },
    "invalid_or_incomplete_setup": {
        "reasons": {"setup_invalid", "setup_incomplete"},
        "routes": {"reporter_setup_correction"},
    },
    "documentation_gap": {
        "reasons": {"documentation_gap_verified"},
        "routes": {"documentation_owner"},
    },
    "product_or_design_decision_required": {
        "reasons": {"product_decision_needed", "api_design_needed"},
        "routes": {"maintainer_design_decision"},
    },
    "ready_for_fix_investigation": {
        "reasons": {"runtime_failure_reproduced", "structural_failure_verified"},
        "routes": {"fix_investigation"},
    },
    "needs_reporter_evidence_or_repro": {
        "reasons": {"reporter_repro_missing", "environment_details_missing"},
        "routes": {"reporter_evidence"},
    },
    "infrastructure_blocked_or_inconclusive": {
        "reasons": {"environment_blocked", "tooling_blocked", "insufficient_evidence"},
        "routes": {"infrastructure_or_retry", "maintainer_recheck_or_reporter_evidence"},
    },
    "not_reproduced": {
        "reasons": {"bounded_repro_did_not_reproduce"},
        "routes": {"maintainer_recheck_or_reporter_evidence"},
    },
    "deferred_below_threshold": {
        "reasons": {"insufficient_customer_or_release_signal"},
        "routes": {"defer"},
    },
}

CHECK_STATUSES = {"passed", "failed", "skipped", "blocked"}
CHECK_CATEGORIES = {
    "triage",
    "setup",
    "supported_usage",
    "history",
    "documentation",
    "proportionality",
    "reproduction",
    "in_tree",
}
RENDER_MODES = {
    None,
    "static_ssr",
    "interactive_server",
    "interactive_webassembly",
    "interactive_auto",
    "standalone_webassembly",
    "not_applicable",
}
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ISSUE_URL_PATTERN = re.compile(r"^https://github\.com/dotnet/aspnetcore/issues/([1-9][0-9]*)$")
GITHUB_WRITE_PATTERN = re.compile(
    r"\bgh\s+(?:issue|pr|repo|release|workflow|run)\s+"
    r"(?:create|edit|comment|close|reopen|delete|merge|review|ready|lock|unlock|"
    r"transfer|dispatch|cancel|rerun)\b",
    re.IGNORECASE,
)


def _parse_recorded_command(command_text):
    try:
        return shlex.split(command_text, posix=True), None
    except ValueError as error:
        return [], f"cannot parse recorded command: {error}"


def _gh_api_method_error(tokens):
    for index in range(len(tokens) - 1):
        if PurePosixPath(tokens[index].replace("\\", "/")).name != "gh" or tokens[
            index + 1
        ] != "api":
            continue

        methods = []
        argument_index = index + 2
        while argument_index < len(tokens):
            argument = tokens[argument_index]
            if argument == "--method" or argument == "-X":
                if argument_index + 1 >= len(tokens):
                    return "gh api method option is missing a value"
                methods.append(tokens[argument_index + 1].upper())
                argument_index += 2
                continue
            if argument.startswith("--method="):
                methods.append(argument.partition("=")[2].upper())
            elif argument.startswith("-X") and argument != "-X":
                methods.append(argument[2:].upper())
            argument_index += 1

        if methods != ["GET"]:
            return "gh api command must use exactly one unambiguous GET method option"

    return None


def _recorded_command_safety_errors(command_text):
    errors = []
    tokens, parse_error = _parse_recorded_command(command_text)
    if parse_error is not None:
        return [parse_error]

    method_error = _gh_api_method_error(tokens)
    if method_error is not None:
        errors.append(method_error)

    inline_flags = {
        "sh": {"-c"},
        "bash": {"-c"},
        "zsh": {"-c"},
        "dash": {"-c"},
        "ksh": {"-c"},
        "fish": {"-c"},
        "cmd": {"/c"},
        "cmd.exe": {"/c"},
        "powershell": {"-command", "-encodedcommand", "-enc"},
        "powershell.exe": {"-command", "-encodedcommand", "-enc"},
        "pwsh": {"-command", "-encodedcommand", "-enc"},
        "pwsh.exe": {"-command", "-encodedcommand", "-enc"},
        "python": {"-c"},
        "python3": {"-c"},
        "node": {"-e", "--eval"},
        "ruby": {"-e"},
        "perl": {"-e"},
    }
    for index, token in enumerate(tokens):
        executable = PurePosixPath(token.replace("\\", "/")).name.lower()
        if executable not in inline_flags:
            continue
        lowered_arguments = {argument.lower() for argument in tokens[index + 1 :]}
        if lowered_arguments.intersection(inline_flags[executable]):
            errors.append("inline shell or evaluator commands are not inspectable")
            break

    for index, token in enumerate(tokens):
        executable = PurePosixPath(token.replace("\\", "/")).name.lower()
        if executable != "env":
            continue
        if any(
            argument in {"-S", "--split-string"}
            or argument.startswith("-S")
            or argument.startswith("--split-string=")
            for argument in tokens[index + 1 :]
        ):
            errors.append("env split-string commands are not inspectable")
            break

    git_options_with_values = {
        "-C",
        "-c",
        "--config-env",
        "--exec-path",
        "--git-dir",
        "--namespace",
        "--super-prefix",
        "--work-tree",
    }
    for index, token in enumerate(tokens):
        if PurePosixPath(token.replace("\\", "/")).name != "git":
            continue
        argument_index = index + 1
        while argument_index < len(tokens):
            argument = tokens[argument_index]
            if argument in git_options_with_values:
                argument_index += 2
                continue
            if any(
                argument.startswith(f"{option}=")
                for option in git_options_with_values
                if option.startswith("--")
            ):
                argument_index += 1
                continue
            if argument.startswith("-"):
                argument_index += 1
                continue
            if argument == "push":
                errors.append("git push is not allowed in a readiness assessment")
            break

    return errors


def _normalize_datetime(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _datetimes_equal(left, right):
    try:
        return _normalize_datetime(left) == _normalize_datetime(right)
    except (AttributeError, TypeError, ValueError):
        return False


def _normalize_state(value):
    return str(value).upper()


def _normalize_state_reason(value):
    if value is None:
        return None
    return str(value).replace("-", "_").upper()


def source_manifest_sha256(source):
    manifest = {
        "skill_commit_sha": source["skill_commit_sha"],
        "artifacts": source["artifacts"],
    }
    content = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(content).hexdigest()


def _validate_nullable_measurement(name, measurement):
    value = measurement["value"]
    unknown_reason = measurement["unknown_reason"]
    if value is None and not unknown_reason:
        return [f"{name} requires unknown_reason when value is null"]
    if value is not None and unknown_reason is not None:
        return [f"{name} unknown_reason must be null when value is known"]
    return []


def _validate_tool_version(name, tool):
    if not tool["used"]:
        if tool["version"] is not None:
            return [f"instrumentation.tools.{name} version must be null when unused"]
        if not tool["unknown_reason"]:
            return [f"instrumentation.tools.{name} requires a not-used reason"]
        return []
    if tool["version"] is None and not tool["unknown_reason"]:
        return [f"instrumentation.tools.{name} requires version or unknown_reason"]
    if tool["version"] is not None and tool["unknown_reason"] is not None:
        return [
            f"instrumentation.tools.{name} unknown_reason must be null when version is known"
        ]
    return []


def _validate_component_version(name, component):
    missing = [
        field for field in ("identifier", "version") if component[field] is None
    ]
    if missing and not component["unknown_reason"]:
        return [
            f"instrumentation.model.{name} requires unknown_reason for missing "
            f"{', '.join(missing)}"
        ]
    if not missing and component["unknown_reason"] is not None:
        return [
            f"instrumentation.model.{name} unknown_reason must be null when complete"
        ]
    return []


def _json_type_matches(value, expected):
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return True


def _resolve_schema_ref(root_schema, reference):
    if not reference.startswith("#/"):
        raise ValueError(f"unsupported schema reference: {reference}")
    current = root_schema
    for part in reference[2:].split("/"):
        current = current[part.replace("~1", "/").replace("~0", "~")]
    return current


def _validate_schema(value, schema, root_schema, path="$"):
    if "$ref" in schema:
        schema = _resolve_schema_ref(root_schema, schema["$ref"])
    if "oneOf" in schema:
        results = [
            _validate_schema(value, candidate, root_schema, path)
            for candidate in schema["oneOf"]
        ]
        if sum(not result for result in results) != 1:
            return [f"{path} must match exactly one allowed schema"]
        return []

    errors = []
    expected_types = schema.get("type")
    if expected_types is not None:
        if isinstance(expected_types, str):
            expected_types = [expected_types]
        if not any(_json_type_matches(value, expected) for expected in expected_types):
            return [f"{path} must have type {' or '.join(expected_types)}"]

    if "const" in schema and value != schema["const"]:
        errors.append(f"{path} must equal {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path} must be one of {schema['enum']!r}")

    if isinstance(value, dict):
        required = schema.get("required", [])
        for name in required:
            if name not in value:
                errors.append(f"{path}.{name} is required")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for name in value:
                if name not in properties:
                    errors.append(f"{path}.{name} is not allowed")
        for name, child in value.items():
            if name in properties:
                errors.extend(_validate_schema(child, properties[name], root_schema, f"{path}.{name}"))

    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{path} must contain at least {schema['minItems']} items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{path} must contain at most {schema['maxItems']} items")
        if schema.get("uniqueItems"):
            serialized = [json.dumps(item, sort_keys=True) for item in value]
            if len(serialized) != len(set(serialized)):
                errors.append(f"{path} must contain unique items")
        item_schema = schema.get("items")
        if item_schema is not None:
            for index, item in enumerate(value):
                errors.extend(_validate_schema(item, item_schema, root_schema, f"{path}[{index}]"))

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{path} is shorter than {schema['minLength']} characters")
        pattern = schema.get("pattern")
        if pattern is not None and re.fullmatch(pattern, value) is None:
            errors.append(f"{path} does not match the required pattern")
        if schema.get("format") == "date-time":
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    raise ValueError
            except ValueError:
                errors.append(f"{path} must be an RFC 3339 date-time with an offset")

    if isinstance(value, int) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path} must be at least {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path} must be at most {schema['maximum']}")

    return errors


def validate_schema(receipt):
    return _validate_schema(receipt, RECEIPT_SCHEMA, RECEIPT_SCHEMA)


def expected_decision(signals):
    if signals["security_report"]:
        return "security_process_required", {"security_boundary"}, {"security_reporting_process"}
    if signals["verified_duplicate"] or signals["verified_already_fixed"]:
        reasons = set()
        if signals["verified_duplicate"]:
            reasons.add("duplicate_verified")
        if signals["verified_already_fixed"]:
            reasons.add("already_fixed_verified")
        return "duplicate_or_already_fixed", reasons, {"existing_issue_or_release"}
    if signals["verified_by_design"]:
        return "by_design", {"upstream_by_design_verified"}, {"stop_by_design"}
    if signals["unsupported_usage"]:
        return (
            "unsupported_usage",
            {"unsupported_configuration_verified"},
            {"supported_usage_guidance"},
        )
    if signals["invalid_or_incomplete_setup"]:
        return (
            "invalid_or_incomplete_setup",
            {"setup_invalid", "setup_incomplete"},
            {"reporter_setup_correction"},
        )
    if signals["documentation_gap"]:
        return "documentation_gap", {"documentation_gap_verified"}, {"documentation_owner"}
    if signals["product_or_design_decision_required"]:
        return (
            "product_or_design_decision_required",
            {"product_decision_needed", "api_design_needed"},
            {"maintainer_design_decision"},
        )
    if signals["runtime_reproduced"]:
        return (
            "ready_for_fix_investigation",
            {"runtime_failure_reproduced"},
            {"fix_investigation"},
        )
    if signals["structural_failure_verified"]:
        return (
            "ready_for_fix_investigation",
            {"structural_failure_verified"},
            {"fix_investigation"},
        )
    if signals["required_reporter_evidence_missing"]:
        return (
            "needs_reporter_evidence_or_repro",
            {"reporter_repro_missing", "environment_details_missing"},
            {"reporter_evidence"},
        )
    if signals["infrastructure_blocked"]:
        return (
            "infrastructure_blocked_or_inconclusive",
            {"environment_blocked", "tooling_blocked"},
            {"infrastructure_or_retry"},
        )
    if signals["runtime_attempted"]:
        return (
            "not_reproduced",
            {"bounded_repro_did_not_reproduce"},
            {"maintainer_recheck_or_reporter_evidence"},
        )
    if signals["below_threshold"]:
        return (
            "deferred_below_threshold",
            {"insufficient_customer_or_release_signal"},
            {"defer"},
        )
    return (
        "infrastructure_blocked_or_inconclusive",
        {"insufficient_evidence"},
        {"maintainer_recheck_or_reporter_evidence"},
    )


def expected_disposition(signals):
    return expected_decision(signals)[0]


def validate_readiness_receipt(receipt):
    errors = validate_schema(receipt)
    if errors:
        return errors

    instrumentation = receipt["instrumentation"]
    source = instrumentation["source"]
    if source_manifest_sha256(source) != source["manifest_sha256"]:
        errors.append("instrumentation.source.manifest_sha256 does not match source manifest")

    timing = instrumentation["timing"]
    started_at = _normalize_datetime(timing["started_at"])
    ended_at = _normalize_datetime(timing["ended_at"])
    if ended_at < started_at:
        errors.append("instrumentation.timing.ended_at must not precede started_at")
    elapsed_seconds = (ended_at - started_at).total_seconds()
    if abs(timing["wall_clock_seconds"] - elapsed_seconds) > 0.001:
        errors.append(
            "instrumentation.timing.wall_clock_seconds must equal ended_at minus started_at"
        )
    if _normalize_datetime(receipt["generated_at"]) != ended_at:
        errors.append("generated_at must equal instrumentation.timing.ended_at")
    active_execution = timing["active_execution"]
    errors.extend(
        _validate_nullable_measurement(
            "instrumentation.timing.active_execution",
            active_execution,
        )
    )
    if (
        active_execution["value"] is not None
        and active_execution["value"] > timing["wall_clock_seconds"]
    ):
        errors.append("active execution duration cannot exceed wall-clock duration")

    for name, tool in instrumentation["tools"].items():
        errors.extend(_validate_tool_version(name, tool))

    model = instrumentation["model"]
    for name, component in model.items():
        errors.extend(_validate_component_version(name, component))

    for name, attempt in instrumentation["attempts"].items():
        errors.extend(
            _validate_nullable_measurement(
                f"instrumentation.attempts.{name}",
                attempt,
            )
        )

    cost = instrumentation["cost"]
    if cost["amount"] is None:
        if any(cost[field] is not None for field in ("currency", "unit", "source")):
            errors.append("unknown instrumentation cost cannot include currency, unit, or source")
        if not cost["unknown_reason"]:
            errors.append("unknown instrumentation cost requires unknown_reason")
    else:
        if any(cost[field] is None for field in ("currency", "unit", "source")):
            errors.append("known instrumentation cost requires currency, unit, and source")
        if cost["unknown_reason"] is not None:
            errors.append("known instrumentation cost requires null unknown_reason")

    if not Path(str(receipt["artifact_root"])).is_absolute():
        errors.append("artifact_root must be an absolute path")

    issue = receipt["issue"]
    match = ISSUE_URL_PATTERN.fullmatch(str(issue.get("url", "")))
    if not isinstance(issue.get("number"), int) or issue["number"] < 1:
        errors.append("issue.number must be a positive integer")
    elif match is None or int(match.group(1)) != issue["number"]:
        errors.append("issue.url must be the canonical URL for issue.number")
    revision = issue.get("revision", {})
    if not revision.get("updated_at"):
        errors.append("issue.revision.updated_at is required")
    if revision.get("state") not in {"OPEN", "CLOSED"}:
        errors.append("issue.revision.state must be OPEN or CLOSED")

    repository = receipt["assessed_repository"]
    if SHA_PATTERN.fullmatch(str(repository.get("sha", ""))) is None:
        errors.append("assessed_repository.sha must be a lowercase 40-character SHA")
    if not isinstance(repository.get("dirty"), bool):
        errors.append("assessed_repository.dirty must be boolean")
    if not Path(repository["path"]).is_absolute():
        errors.append("assessed_repository.path must be an absolute path")

    environment = receipt["environment"]
    if environment.get("render_mode") not in RENDER_MODES:
        errors.append("environment.render_mode is invalid")

    upstream_triage = receipt["upstream_triage"]

    investigation = receipt["investigation"]
    highest_tier = investigation.get("highest_tier")
    if not isinstance(highest_tier, int) or not 0 <= highest_tier <= 4:
        errors.append("investigation.highest_tier must be an integer from 0 through 4")

    signals = receipt["decision_signals"]
    if errors:
        return errors

    evidence = receipt["evidence"]
    evidence_by_id = {item["id"]: item for item in evidence}
    evidence_ids = set()
    for index, item in enumerate(evidence):
        evidence_id = item.get("id")
        if not evidence_id or evidence_id in evidence_ids:
            errors.append(f"evidence[{index}].id must be non-empty and unique")
        evidence_ids.add(evidence_id)
        raw_path = str(item.get("path", ""))
        path = PurePosixPath(raw_path)
        if "\\" in raw_path or path.is_absolute() or ".." in path.parts or str(path) in {"", "."}:
            errors.append(f"evidence[{index}].path must be a safe artifact-root-relative path")
        if SHA256_PATTERN.fullmatch(str(item.get("sha256", ""))) is None:
            errors.append(f"evidence[{index}].sha256 must be a lowercase SHA-256")

    commands = receipt["commands"]
    command_ids = set()
    command_by_id = {}
    for index, command in enumerate(commands):
        command_id = command.get("id")
        if not command_id or command_id in command_ids:
            errors.append(f"commands[{index}].id must be non-empty and unique")
        command_ids.add(command_id)
        command_by_id[command_id] = command
        command_text = command["command"]
        if GITHUB_WRITE_PATTERN.search(command_text) or re.search(
            r"\bgit\s+push\b"
            r"|\bcurl\b[^\n]*(?:-X|--request)\s*(?:POST|PUT|PATCH|DELETE)\b"
            r"|\bcurl\b[^\n]*(?:^|\s)(?:-d|-F|-T|--data(?:-[\w-]+)?|--form(?:-string)?"
            r"|--upload-file|--json)(?:=|\s)"
            r"|\bwget\b[^\n]*(?:--post-data|--post-file|--method)(?:=|\s)",
            command_text,
            re.IGNORECASE,
        ):
            errors.append(f"commands[{index}] contradicts the read-only safety attestation")
        for command_error in _recorded_command_safety_errors(command_text):
            errors.append(f"commands[{index}] {command_error}")
        if not Path(command["working_directory"]).is_absolute():
            errors.append(f"commands[{index}].working_directory must be an absolute path")
        for ref_name in ("stdout_ref", "stderr_ref"):
            ref = command.get(ref_name)
            if ref is not None and ref not in evidence_ids:
                errors.append(f"commands[{index}].{ref_name} references unknown evidence '{ref}'")

    checks = receipt["checks"]
    if not checks:
        errors.append("checks must contain at least one check")
    check_ids = set()
    counts = Counter()
    reproduction_passed = False
    decisive_checks = []
    for index, check in enumerate(checks):
        check_id = check.get("id")
        if not check_id or check_id in check_ids:
            errors.append(f"checks[{index}].id must be non-empty and unique")
        check_ids.add(check_id)
        status = check.get("status")
        category = check.get("category")
        if status not in CHECK_STATUSES:
            errors.append(f"checks[{index}].status is invalid")
        else:
            counts[status] += 1
        if category not in CHECK_CATEGORIES:
            errors.append(f"checks[{index}].category is invalid")
        for command_id in check.get("command_ids", []):
            if command_id not in command_ids:
                errors.append(f"checks[{index}] references unknown command '{command_id}'")
        refs = check.get("evidence_refs", [])
        for evidence_id in refs:
            if evidence_id not in evidence_ids:
                errors.append(f"checks[{index}] references unknown evidence '{evidence_id}'")
        required_evidence_kinds = {
            "history": {"history", "comment_snapshot"},
            "documentation": {"documentation"},
            "proportionality": {"proportionality"},
        }.get(category)
        has_category_evidence = required_evidence_kinds is None or any(
            evidence_by_id[evidence_id]["kind"] in required_evidence_kinds
            for evidence_id in refs
            if evidence_id in evidence_by_id
        )
        if required_evidence_kinds is not None and refs and not has_category_evidence:
            errors.append(
                f"checks[{index}] category '{category}' requires matching evidence kind"
            )
        if refs and has_category_evidence:
            decisive_checks.append(check)
        if category == "reproduction" and status == "passed" and refs:
            passed_commands = [
                command_by_id[command_id]
                for command_id in check["command_ids"]
                if command_id in command_by_id
                and command_by_id[command_id]["status"] == "passed"
                and command_by_id[command_id]["exit_code"] == 0
            ]
            has_command_output = any(
                evidence_by_id[evidence_id]["kind"] == "command_output"
                for evidence_id in refs
                if evidence_id in evidence_by_id
            )
            reproduction_passed = bool(passed_commands) and has_command_output

    runtime_command_ids = {
        command_id
        for check in checks
        if check["category"] in {"reproduction", "in_tree"} and check["status"] != "skipped"
        for command_id in check["command_ids"]
    }
    executed_runtime_command_ids = {
        command_id
        for command_id in runtime_command_ids
        if command_id in command_by_id
        and command_by_id[command_id]["status"] in {"passed", "failed"}
        and command_by_id[command_id]["exit_code"] is not None
    }
    runtime_execution_recorded = bool(executed_runtime_command_ids)
    if runtime_execution_recorded and not signals["runtime_attempted"]:
        errors.append("recorded reproduction or in-tree execution requires runtime_attempted")
    if signals["runtime_attempted"] and not runtime_execution_recorded:
        errors.append("runtime_attempted requires a recorded reproduction or in-tree execution")
    reproduction_attempts = instrumentation["attempts"]["reproduction"]["value"]
    if signals["runtime_attempted"] and reproduction_attempts == 0:
        errors.append("runtime_attempted requires at least one reproduction attempt")

    summary = receipt["check_summary"]
    expected_summary = {
        "attempted": counts["passed"] + counts["failed"] + counts["blocked"],
        "passed": counts["passed"],
        "failed": counts["failed"],
        "skipped": counts["skipped"],
        "blocked": counts["blocked"],
    }
    if summary != expected_summary:
        errors.append(f"check_summary must equal {expected_summary}")

    disposition = receipt["primary_disposition"]
    expected, expected_reasons, expected_routes = expected_decision(signals)
    if disposition != expected:
        errors.append(
            f"primary_disposition '{disposition}' violates precedence; expected '{expected}'"
        )
    if disposition not in DISPOSITIONS:
        errors.append(f"primary_disposition '{disposition}' is invalid")
    else:
        if receipt["reason_code"] not in expected_reasons:
            errors.append(
                f"reason_code '{receipt['reason_code']}' is not valid for the winning decision row"
            )
        if receipt["next_route"] not in expected_routes:
            errors.append(
                f"next_route '{receipt['next_route']}' is not valid for the winning decision row"
            )

    resolution_reference = receipt["resolution_reference"]
    if expected == "duplicate_or_already_fixed":
        if resolution_reference is None:
            errors.append("duplicate_or_already_fixed requires a resolution_reference")
        else:
            reference_patterns = {
                "issue": re.compile(
                    r"^https://github\.com/dotnet/aspnetcore/issues/[1-9][0-9]*$"
                ),
                "pull_request": re.compile(
                    r"^https://github\.com/dotnet/aspnetcore/pull/[1-9][0-9]*$"
                ),
                "release": re.compile(
                    r"^https://github\.com/dotnet/aspnetcore/releases/tag/\S+$"
                ),
            }
            if (
                reference_patterns[resolution_reference["kind"]].fullmatch(
                    resolution_reference["url"]
                )
                is None
            ):
                errors.append("resolution_reference URL does not match its kind")
            if resolution_reference["evidence_ref"] not in evidence_ids:
                errors.append("resolution_reference references unknown evidence")
            if not any(
                resolution_reference["evidence_ref"] in check["evidence_refs"]
                for check in decisive_checks
            ):
                errors.append("resolution_reference must be cited by a decisive check")

    decisive_requirements = {
        "security_process_required": ({"triage"}, {"passed"}),
        "duplicate_or_already_fixed": ({"triage"}, {"passed"}),
        "by_design": ({"history", "documentation"}, {"passed"}),
        "unsupported_usage": ({"supported_usage", "documentation"}, {"passed"}),
        "invalid_or_incomplete_setup": ({"setup"}, {"passed"}),
        "documentation_gap": ({"documentation"}, {"passed"}),
        "product_or_design_decision_required": (
            {"history", "documentation"},
            {"passed"},
        ),
        "ready_for_fix_investigation": ({"reproduction", "in_tree"}, {"passed"}),
        "needs_reporter_evidence_or_repro": ({"triage", "setup"}, {"passed"}),
        "infrastructure_blocked_or_inconclusive": (
            CHECK_CATEGORIES,
            {"blocked"} if signals["infrastructure_blocked"] else CHECK_STATUSES,
        ),
        "not_reproduced": ({"reproduction"}, {"failed"}),
        "deferred_below_threshold": ({"proportionality"}, {"passed"}),
    }
    required_categories, required_statuses = decisive_requirements[expected]
    if not any(
        check["category"] in required_categories and check["status"] in required_statuses
        for check in decisive_checks
    ):
        errors.append(f"{expected} requires a decisive check with evidence")

    if signals["runtime_reproduced"] and not signals["runtime_attempted"]:
        errors.append("runtime_reproduced requires runtime_attempted")
    if disposition == "ready_for_fix_investigation":
        if investigation["runtime_evidence_feasible"] and not reproduction_passed:
            errors.append(
                "ready_for_fix_investigation requires a passed reproduction check with evidence "
                "when runtime evidence is feasible"
            )
        if (
            not investigation["runtime_evidence_feasible"]
            and receipt["reason_code"] != "structural_failure_verified"
        ):
            errors.append(
                "ready without feasible runtime evidence requires structural_failure_verified"
            )
        if (
            receipt["reason_code"] == "structural_failure_verified"
            and not signals["structural_failure_verified"]
        ):
            errors.append("structural_failure_verified reason requires its decision signal")
    if disposition == "not_reproduced" and receipt["next_route"] == "stop_by_design":
        errors.append("not_reproduced must not imply closure or by-design")
    if disposition == "needs_reporter_evidence_or_repro" and not receipt["missing_evidence"]:
        errors.append("needs_reporter_evidence_or_repro requires missing_evidence")
    if disposition == "infrastructure_blocked_or_inconclusive" and signals["infrastructure_blocked"]:
        if not receipt["blockers"]:
            errors.append("an infrastructure-blocked receipt requires blockers")
        if receipt["confidence"] == "high":
            errors.append("an infrastructure-blocked receipt cannot have high confidence")
    if (
        "area-blazor" in upstream_triage["labels"]
        and signals["runtime_attempted"]
        and not investigation["components_validator_delegated"]
    ):
        errors.append("Blazor runtime assessment must delegate to validate-blazor-feature")

    safety = receipt["safety"]
    if safety.get("github_mutations") != []:
        errors.append("safety.github_mutations must be empty")
    if safety.get("microsoft_365_writes") != []:
        errors.append("safety.microsoft_365_writes must be empty")
    if safety.get("fixes_proposed") is not False:
        errors.append("safety.fixes_proposed must be false")
    if safety.get("fixes_implemented") is not False:
        errors.append("safety.fixes_implemented must be false")

    if safety["input_mode"] == "public_get_snapshot":
        if safety["github_access"] != "public_get_only":
            errors.append("public_get_snapshot requires github_access public_get_only")
        if safety["acquisition_external_network_access"] != "public_github_get_only":
            errors.append(
                "public_get_snapshot requires acquisition_external_network_access "
                "public_github_get_only"
            )
    else:
        if safety["github_access"] != "none":
            errors.append("provided_offline_snapshot requires github_access none")
        if safety["acquisition_external_network_access"] != "none":
            errors.append("provided_offline_snapshot requires no acquisition network access")

    if safety["assessment_mode"] == "offline_no_credentials":
        if safety["credentials_removed"] is not True:
            errors.append("offline_no_credentials requires credentials_removed")
        if safety["assessment_external_network_access"] != "none":
            errors.append("offline_no_credentials requires no external assessment network")

    if safety["execution_boundary"] == "host_attestation":
        if safety["hard_no_mutation_guarantee"]:
            errors.append("host_attestation cannot claim a hard no-mutation guarantee")
    else:
        if safety["assessment_mode"] != "offline_no_credentials":
            errors.append(
                "isolated_no_credentials_no_write_tools requires offline_no_credentials assessment"
            )
        if safety["credentials_removed"] is not True:
            errors.append("isolated_no_credentials_no_write_tools requires credentials_removed")
        if safety["assessment_external_network_access"] != "none":
            errors.append(
                "isolated_no_credentials_no_write_tools requires no external assessment network"
            )
    if safety["hard_no_mutation_guarantee"]:
        if safety["github_access"] not in {"none", "public_get_only"}:
            errors.append("hard guarantee allows only none or public_get_only GitHub access")

    artifact_root = Path(receipt["artifact_root"]).resolve()
    source_worktree = Path(repository["path"]).resolve()
    disposable_root_value = safety["disposable_worktree_root"]
    disposable_root = (
        Path(disposable_root_value).resolve() if disposable_root_value is not None else None
    )
    cache_roots = [Path(path).resolve() for path in safety["cache_roots"]]
    temp_roots = [Path(path).resolve() for path in safety["temp_roots"]]
    writable_roots = [Path(path).resolve() for path in safety["writable_roots"]]
    expected_writable_roots = [artifact_root]
    if disposable_root is not None:
        expected_writable_roots.append(disposable_root)
    expected_writable_roots.extend(cache_roots)
    expected_writable_roots.extend(temp_roots)

    root_fields = [
        ("artifact_root", receipt["artifact_root"]),
        ("assessed_repository.path", repository["path"]),
        ("disposable_worktree_root", disposable_root_value),
        *[("cache_roots", path) for path in safety["cache_roots"]],
        *[("temp_roots", path) for path in safety["temp_roots"]],
        *[("writable_roots", path) for path in safety["writable_roots"]],
    ]
    for field, path in root_fields:
        if path is not None and not Path(path).is_absolute():
            errors.append(f"{field} entries must be absolute paths")

    if set(writable_roots) != set(expected_writable_roots):
        errors.append(
            "writable_roots must exactly contain artifact_root plus the recorded "
            "disposable worktree, cache, and temp roots"
        )
    for writable_root in writable_roots:
        if (
            writable_root == source_worktree
            or writable_root.is_relative_to(source_worktree)
            or source_worktree.is_relative_to(writable_root)
        ):
            errors.append("writable_roots must not overlap the user's source worktree")

    runtime_scope = signals["runtime_attempted"] or runtime_execution_recorded
    if runtime_scope:
        if safety["reproduction_isolation"] != "sandboxed_no_credentials":
            errors.append("runtime attempts require sandboxed_no_credentials isolation")
        if safety["credentials_removed"] is not True:
            errors.append("runtime attempts require credentials_removed")
        if safety["assessment_external_network_access"] != "none":
            errors.append("runtime attempts require no external assessment network")
        if any(
            check["category"] == "in_tree" and check["status"] != "skipped"
            for check in checks
        ) and disposable_root is None:
            errors.append("in-tree checks require a disposable_worktree_root")

        for command_id in runtime_command_ids:
            command = command_by_id.get(command_id)
            if command is None:
                continue
            working_directory = Path(command["working_directory"]).resolve()
            if working_directory == source_worktree or working_directory.is_relative_to(
                source_worktree
            ):
                errors.append(
                    f"runtime command '{command_id}' must not run in the user's source worktree"
                )
            if not any(
                working_directory == writable_root
                or working_directory.is_relative_to(writable_root)
                for writable_root in writable_roots
            ):
                errors.append(
                    f"runtime command '{command_id}' must run beneath an authorized writable root"
                )
    else:
        if safety["reproduction_isolation"] != "not_applicable":
            errors.append(
                "reproduction_isolation must be not_applicable without recorded runtime execution"
            )

    interactive_render_modes = {
        "interactive_server",
        "interactive_webassembly",
        "interactive_auto",
        "standalone_webassembly",
    }
    if (
        runtime_scope
        and receipt["environment"]["render_mode"] in interactive_render_modes
        and safety["loopback_network_access"] is not True
    ):
        errors.append("interactive runtime assessment requires loopback_network_access")

    for field in ("supporting_findings", "missing_evidence", "blockers"):
        if not isinstance(receipt[field], list):
            errors.append(f"{field} must be an array")

    return errors


def validate_readiness_evidence_files(receipt, receipt_path):
    errors = []
    artifact_root = Path(receipt["artifact_root"]).resolve()
    repository_root = Path(__file__).resolve().parents[4]
    if artifact_root == repository_root or artifact_root.is_relative_to(repository_root):
        errors.append("artifact_root must be outside the repository")
    if receipt_path.resolve().parent != artifact_root:
        errors.append("receipt must be stored directly beneath artifact_root")

    for index, item in enumerate(receipt["evidence"]):
        evidence_path = (artifact_root / item["path"]).resolve()
        if not evidence_path.is_relative_to(artifact_root):
            errors.append(f"evidence[{index}] escapes artifact_root: {item['path']}")
            continue
        if not evidence_path.is_file():
            errors.append(f"evidence[{index}] file does not exist: {item['path']}")
            continue
        digest = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
        if digest != item["sha256"]:
            errors.append(f"evidence[{index}] SHA-256 does not match: {item['path']}")

    issue_number = receipt["issue"]["number"]
    issue_url = receipt["issue"]["url"]
    issue_api_url = (
        f"https://api.github.com/repos/dotnet/aspnetcore/issues/{issue_number}"
    )
    primary_evidence = [
        item
        for item in receipt["evidence"]
        if item["kind"] == "issue_snapshot"
        and item["source"] in {issue_url, f"GET {issue_api_url}"}
    ]
    primary_issue = None
    if len(primary_evidence) != 1:
        errors.append("receipt requires exactly one primary issue_snapshot evidence")
    else:
        primary_path = (artifact_root / primary_evidence[0]["path"]).resolve()
        try:
            primary_issue = json.loads(primary_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f"invalid primary issue snapshot: {error}")
        else:
            if primary_issue.get("number") != issue_number:
                errors.append("primary issue snapshot number does not match receipt")
            if primary_issue.get("html_url") != issue_url:
                errors.append("primary issue snapshot URL does not match receipt")
            if (
                primary_issue.get("repository_url")
                != "https://api.github.com/repos/dotnet/aspnetcore"
            ):
                errors.append("primary issue snapshot repository is not dotnet/aspnetcore")
            if "pull_request" in primary_issue:
                errors.append("primary issue snapshot is a pull request, not an issue")
            if not _datetimes_equal(
                primary_issue.get("updated_at"),
                receipt["issue"]["revision"]["updated_at"],
            ):
                errors.append(
                    "primary issue snapshot updated_at does not match receipt revision"
                )
            if _normalize_state(primary_issue.get("state")) != receipt["issue"][
                "revision"
            ]["state"]:
                errors.append("primary issue snapshot state does not match receipt revision")
            if _normalize_state_reason(
                primary_issue.get("state_reason")
            ) != _normalize_state_reason(receipt["issue"]["revision"]["state_reason"]):
                errors.append(
                    "primary issue snapshot state_reason does not match receipt revision"
                )

    if receipt["safety"]["input_mode"] == "public_get_snapshot":
        manifests = [
            item for item in receipt["evidence"] if item["kind"] == "acquisition_manifest"
        ]
        if len(manifests) != 1:
            errors.append("public_get_snapshot requires exactly one acquisition_manifest")
        else:
            manifest_path = (artifact_root / manifests[0]["path"]).resolve()
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                errors.append(f"invalid acquisition_manifest: {error}")
            else:
                if manifest.get("authenticated") is not False:
                    errors.append("acquisition_manifest must record authenticated false")
                if manifest.get("input_mode") != "public_get_snapshot":
                    errors.append("acquisition_manifest input_mode must be public_get_snapshot")
                if manifest.get("source_repository") != "dotnet/aspnetcore":
                    errors.append("acquisition_manifest source_repository is invalid")
                if manifest.get("issue_number") != receipt["issue"]["number"]:
                    errors.append("acquisition_manifest issue_number does not match receipt")
                files = manifest.get("files")
                if not isinstance(files, list) or not files:
                    errors.append("acquisition_manifest files must be a non-empty array")
                else:
                    source_pattern = re.compile(
                        r"^https://api\.github\.com/repos/dotnet/aspnetcore/issues/"
                        r"[1-9][0-9]*(?:/comments)?$"
                    )
                    for index, item in enumerate(files):
                        if item.get("method") != "GET":
                            errors.append(
                                f"acquisition_manifest.files[{index}] method must be GET"
                            )
                        if source_pattern.fullmatch(str(item.get("source", ""))) is None:
                            errors.append(
                                f"acquisition_manifest.files[{index}] source is not allowed"
                            )
                        relative_path = PurePosixPath(str(item.get("path", "")))
                        if (
                            relative_path.is_absolute()
                            or ".." in relative_path.parts
                            or "\\" in str(relative_path)
                        ):
                            errors.append(
                                f"acquisition_manifest.files[{index}] path is unsafe"
                            )
                            continue
                        acquired_path = (artifact_root / relative_path).resolve()
                        if not acquired_path.is_relative_to(artifact_root):
                            errors.append(
                                f"acquisition_manifest.files[{index}] escapes artifact_root"
                            )
                            continue
                        if not acquired_path.is_file():
                            errors.append(
                                f"acquisition_manifest.files[{index}] file does not exist"
                            )
                            continue
                        digest = hashlib.sha256(acquired_path.read_bytes()).hexdigest()
                        if digest != item.get("sha256"):
                            errors.append(
                                f"acquisition_manifest.files[{index}] SHA-256 does not match"
                            )

                    primary_source = (
                        "https://api.github.com/repos/dotnet/aspnetcore/issues/"
                        f"{receipt['issue']['number']}"
                    )
                    primary_files = [
                        item for item in files if item.get("source") == primary_source
                    ]
                    if len(primary_files) != 1:
                        errors.append(
                            "acquisition_manifest must contain exactly one primary issue snapshot"
                        )
                    else:
                        if len(primary_evidence) == 1 and (
                            primary_files[0].get("path") != primary_evidence[0]["path"]
                            or primary_files[0].get("sha256")
                            != primary_evidence[0]["sha256"]
                        ):
                            errors.append(
                                "acquisition_manifest primary issue does not match "
                                "receipt issue_snapshot evidence"
                            )

    resolution_reference = receipt["resolution_reference"]
    if resolution_reference is not None:
        matching_evidence = [
            item
            for item in receipt["evidence"]
            if item["id"] == resolution_reference["evidence_ref"]
        ]
        if len(matching_evidence) == 1:
            reference_path = (artifact_root / matching_evidence[0]["path"]).resolve()
            try:
                reference_snapshot = json.loads(reference_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                errors.append(f"invalid resolution_reference evidence: {error}")
            else:
                if reference_snapshot.get("html_url") != resolution_reference["url"]:
                    errors.append(
                        "resolution_reference URL does not match its evidence snapshot"
                    )

    return errors


def main():
    parser = argparse.ArgumentParser(description="Validate an issue readiness receipt.")
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()

    try:
        receipt = json.loads(args.receipt.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"INVALID: {error}", file=sys.stderr)
        return 1

    try:
        errors = validate_readiness_receipt(receipt)
    except (AttributeError, KeyError, TypeError, ValueError) as error:
        errors = [f"malformed receipt: {error}"]
    if not errors:
        errors.extend(validate_readiness_evidence_files(receipt, args.receipt))
    if errors:
        for error in errors:
            print(f"INVALID: {error}", file=sys.stderr)
        return 1

    print(
        f"VALID: {receipt['assessment_id']} -> "
        f"{receipt['primary_disposition']} ({receipt['confidence']})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
