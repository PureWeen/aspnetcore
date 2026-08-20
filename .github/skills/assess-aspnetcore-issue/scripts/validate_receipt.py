#!/usr/bin/env python3

import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path, PurePosixPath


SCHEMA_PATH = Path(__file__).resolve().parents[1] / "references" / "receipt.schema.json"
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
        "routes": {"aspnetcore_try_fix"},
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
            {"aspnetcore_try_fix"},
        )
    if signals["structural_failure_verified"]:
        return (
            "ready_for_fix_investigation",
            {"structural_failure_verified"},
            {"aspnetcore_try_fix"},
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


def validate_receipt(receipt):
    errors = validate_schema(receipt)
    if errors:
        return errors

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
            r"\bgit\s+push\b|\bcurl\b[^\n]*(?:-X|--request)\s*(?:POST|PUT|PATCH|DELETE)\b",
            command_text,
            re.IGNORECASE,
        ):
            errors.append(f"commands[{index}] contradicts the read-only safety contract")
        if re.search(r"\bgh\s+api\b", command_text, re.IGNORECASE):
            methods = re.findall(r"--method(?:=|\s+)([A-Z]+)\b", command_text, re.IGNORECASE)
            if [method.upper() for method in methods] != ["GET"]:
                errors.append(f"commands[{index}] gh api command must use exactly one --method GET")
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
        if refs:
            decisive_checks.append(check)
        if category == "reproduction" and status == "passed" and refs:
            passed_commands = [
                command_by_id[command_id]
                for command_id in check["command_ids"]
                if command_id in command_by_id
                and command_by_id[command_id]["status"] == "passed"
                and command_by_id[command_id]["exit_code"] == 0
            ]
            evidence_by_id = {item["id"]: item for item in evidence}
            has_command_output = any(
                evidence_by_id[evidence_id]["kind"] == "command_output"
                for evidence_id in refs
                if evidence_id in evidence_by_id
            )
            reproduction_passed = bool(passed_commands) and has_command_output

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

    decisive_requirements = {
        "security_process_required": ({"triage"}, {"passed"}),
        "duplicate_or_already_fixed": ({"triage"}, {"passed"}),
        "by_design": ({"triage", "documentation"}, {"passed"}),
        "unsupported_usage": ({"supported_usage", "documentation"}, {"passed"}),
        "invalid_or_incomplete_setup": ({"setup"}, {"passed"}),
        "documentation_gap": ({"documentation"}, {"passed"}),
        "product_or_design_decision_required": (
            {"triage", "history", "documentation"},
            {"passed"},
        ),
        "ready_for_fix_investigation": ({"reproduction", "in_tree"}, {"passed"}),
        "needs_reporter_evidence_or_repro": ({"triage", "setup"}, {"passed"}),
        "infrastructure_blocked_or_inconclusive": (
            CHECK_CATEGORIES,
            {"blocked"} if signals["infrastructure_blocked"] else CHECK_STATUSES,
        ),
        "not_reproduced": ({"reproduction"}, {"failed"}),
        "deferred_below_threshold": ({"triage"}, {"passed"}),
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
    if safety.get("github_access") != "read_only":
        errors.append("safety.github_access must be read_only")
    if safety.get("github_mutations") != []:
        errors.append("safety.github_mutations must be empty")
    if safety.get("microsoft_365_writes") != []:
        errors.append("safety.microsoft_365_writes must be empty")
    if safety.get("fixes_proposed") is not False:
        errors.append("safety.fixes_proposed must be false")
    if safety.get("fixes_implemented") is not False:
        errors.append("safety.fixes_implemented must be false")
    if signals["runtime_attempted"]:
        if safety["reproduction_isolation"] != "sandboxed_no_credentials":
            errors.append("runtime attempts require sandboxed_no_credentials isolation")
        if safety["credentials_removed"] is not True:
            errors.append("runtime attempts require credentials_removed")
        if safety["network_access"] != "none":
            errors.append("runtime attempts require network_access none")
        if safety["writable_roots"] != [receipt["artifact_root"]]:
            errors.append("runtime attempts must restrict writes to artifact_root")
    else:
        if safety["reproduction_isolation"] != "not_applicable":
            errors.append("reproduction_isolation must be not_applicable without runtime attempts")
        if safety["network_access"] != "not_applicable":
            errors.append("network_access must be not_applicable without runtime attempts")
        if safety["writable_roots"]:
            errors.append("writable_roots must be empty without runtime attempts")

    for field in ("supporting_findings", "missing_evidence", "blockers"):
        if not isinstance(receipt[field], list):
            errors.append(f"{field} must be an array")

    return errors


def validate_evidence_files(receipt, receipt_path):
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

    return errors


def main():
    parser = argparse.ArgumentParser(description="Validate an issue actionability receipt.")
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()

    try:
        receipt = json.loads(args.receipt.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"INVALID: {error}", file=sys.stderr)
        return 1

    try:
        errors = validate_receipt(receipt)
    except (AttributeError, KeyError, TypeError, ValueError) as error:
        errors = [f"malformed receipt: {error}"]
    if not errors:
        errors.extend(validate_evidence_files(receipt, args.receipt))
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
