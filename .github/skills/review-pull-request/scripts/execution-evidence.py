#!/usr/bin/env python3
"""Validate optional, untrusted execution evidence against the prepared source bundle."""
import copy
import json
import os
import pathlib
import re
import sys

CLASSES = {"red-green", "green-green", "head-red", "red-compile", "zero-tests",
           "infra-failure", "unsupported", "not-applicable", "mixed"}
AVAILABLE = {"red-green", "green-green", "not-applicable"}


def unavailable(target, reason):
    return {"schemaVersion": 1, "headSha": target["head"], "mergeBaseSha": target["mergeBase"],
            "baseTipSha": target["baseTip"], "classification": "infra-failure",
            "available": False, "reason": reason, "supportingEvidenceOnly": True}


def normalize(report, target):
    if not isinstance(report, dict) or report.get("schemaVersion") != 1:
        return unavailable(target, "execution report is malformed or has an unsupported schema")
    for field, role in (("headSha", "head"), ("mergeBaseSha", "mergeBase"), ("baseTipSha", "baseTip")):
        if report.get(field) != target[role]:
            return unavailable(target, "execution report " + field + " does not match the frozen source bundle")
    classification = report.get("classification")
    if classification not in CLASSES:
        return unavailable(target, "execution report has an unknown classification")
    if classification in {"red-green", "green-green"}:
        if classification == "red-green" and not report.get("revertedFiles"):
            return unavailable(target, "execution report has no reverted product change")
        plans, results = report.get("plan"), report.get("results")
        if not isinstance(plans, list) or not plans or not isinstance(results, list):
            return unavailable(target, "execution report has no complete test plan/results")
        if report.get("unsupported") or report.get("restoredHead") is not True:
            return unavailable(target, "execution report has unsupported selections or an unrestored tree")
        pairs = []
        for index in range(len(plans)):
            pair = []
            for tree in ("head", "reverted"):
                matches = [r for r in results if r.get("planIndex") == index and r.get("tree") == tree]
                if len(matches) != 1:
                    return unavailable(target, "execution report is missing a unique head/reverted result")
                r = matches[0]
                if any(type(r.get(k)) is not int or r[k] < 0 for k in ("passed", "failed", "skipped", "total", "exitCode")):
                    return unavailable(target, "execution report has invalid result counts")
                if (r["passed"] + r["failed"] == 0 or r["total"] != r["passed"] + r["failed"] + r["skipped"]
                        or not r.get("reportFound") or r.get("runtimeErrorSuites", 0)):
                    return unavailable(target, "execution report has no complete executed-test evidence")
                cases = r.get("testCases", [])
                if (not cases or len(cases) != r["total"] or
                        sum(c.get("outcome", "").lower() == "passed" for c in cases) != r["passed"] or
                        sum(c.get("outcome", "").lower() == "failed" for c in cases) != r["failed"]):
                    return unavailable(target, "execution report case identities/counts are incomplete")
                pair.append(r)
            head, reverted = pair
            if sorted(c["name"] for c in head["testCases"]) != sorted(c["name"] for c in reverted["testCases"]):
                return unavailable(target, "execution report head/reverted test identities differ")
            if head["failed"] or head["exitCode"] != 0:
                return unavailable(target, "execution report head did not pass")
            expected = "red-green" if reverted["failed"] and reverted["exitCode"] != 0 else (
                "green-green" if reverted["failed"] == 0 and reverted["exitCode"] == 0 else None)
            pairs.append(expected)
        if any(p != classification for p in pairs):
            return unavailable(target, "execution report classification does not match test results")
    if classification == "not-applicable":
        files = report.get("changedFiles")
        if (not isinstance(files, list) or any(f.get("kind") != "docs-only" for f in files) or
                report.get("plan") or report.get("unsupported") or report.get("steps")):
            return unavailable(target, "execution report does not establish docs-only non-applicability")
    result = copy.deepcopy(report)
    result["available"] = classification in AVAILABLE
    result["supportingEvidenceOnly"] = True
    # Artifact strings are data, never Actions outputs, environment assignments, or instructions.
    reason = report.get("reason", classification)
    if not isinstance(reason, str):
        reason = classification
    result["reason"] = re.sub(r"[\x00-\x1f\x7f]", " ", reason).strip()[:240] or classification
    return result


def self_test():
    target = {"head": "a" * 40, "mergeBase": "b" * 40, "baseTip": "c" * 40}
    base = {"schemaVersion": 1, "headSha": target["head"], "mergeBaseSha": target["mergeBase"],
            "baseTipSha": target["baseTip"], "classification": "not-applicable",
            "changedFiles": [{"kind": "docs-only"}], "reason": "docs-only"}
    assert normalize(base, target)["available"]
    for key in ("headSha", "mergeBaseSha", "baseTipSha"):
        altered = {**base, key: "d" * 40}
        assert not normalize(altered, target)["available"], key
    assert not normalize(None, target)["available"]
    assert not normalize({**base, "classification": "pending"}, target)["available"]
    assert not normalize({**base, "changedFiles": [{"kind": "product"}]}, target)["available"]
    for outcome in CLASSES - AVAILABLE:
        normalized = normalize({**base, "classification": outcome, "reason": "line\nother" * 100}, target)
        assert not normalized["available"] and len(normalized["reason"]) <= 240 and "\n" not in normalized["reason"]
    assert not normalize({**base, "classification": "red-green", "plan": []}, target)["available"]
    pair = {**base, "classification": "red-green", "plan": [{"files": ["test.cs"]}],
            "unsupported": [], "restoredHead": True, "results": [], "revertedFiles": ["src/Product.cs"]}
    for tree, passed, failed in (("head", 2, 0), ("reverted", 1, 1)):
        pair["results"].append({"planIndex": 0, "tree": tree, "passed": passed, "failed": failed,
                               "skipped": 0, "total": 2, "exitCode": 1 if failed else 0,
                               "reportFound": True, "testCases": [
                                   {"name": "first", "outcome": "Passed"},
                                   {"name": "second", "outcome": "Failed" if failed else "Passed"}]})
    assert normalize(pair, target)["available"]
    green = copy.deepcopy(pair)
    green["classification"] = "green-green"
    green["results"][1] = {**copy.deepcopy(green["results"][0]), "tree": "reverted"}
    assert normalize(green, target)["available"]
    for change in ({"total": 0, "passed": 0, "failed": 0},
                   {"total": 2, "passed": 0, "failed": 0, "skipped": 2},
                   {"reportFound": False}, {"runtimeErrorSuites": 1}, {"exitCode": 1}):
        altered = copy.deepcopy(pair)
        altered["results"][0].update(change)
        assert not normalize(altered, target)["available"], change
    altered = copy.deepcopy(pair)
    altered["results"][1]["testCases"][0]["name"] = "different"
    assert not normalize(altered, target)["available"]
    altered = {**pair, "unsupported": [{"path": "other"}]}
    assert not normalize(altered, target)["available"]
    assert not normalize({**pair, "revertedFiles": []}, target)["available"]
    print("Normalizer: identities, all classifications, counts, all-skipped, missing reports, partial unsupported: passed")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    report_path, manifest_path, output_path = map(pathlib.Path, sys.argv[1:4])
    # Required source-bundle failures intentionally remain fatal.
    manifest = json.loads(manifest_path.read_text())
    target = manifest["target"]
    try:
        if report_path.stat().st_size > 16 * 1024 * 1024:
            raise ValueError("oversized execution report")
        report = json.loads(report_path.read_text())
        result = normalize(report, target)
    except FileNotFoundError:
        job_result = os.environ.get("REVIEW_EXECUTION_JOB_RESULT", "unknown")
        if job_result not in {"success", "failure", "cancelled", "skipped"}:
            job_result = "unknown"
        result = unavailable(target, "execution artifact is missing; review_execution job result: " + job_result)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        result = unavailable(target, "execution artifact is unreadable or malformed")
    output_path.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
