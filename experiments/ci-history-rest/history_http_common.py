"""Wire validation extracted from the closed HTTP spike; no source access."""

import hashlib
import json


CONTRACT_SHA256 = "a3f63bb1d6d11455ca7fe569431051cfac88bd0427752247b5cd8962e9e7fe7e"
MAX_REQUEST = 65536
MAX_RESPONSE = 2 * 1024 * 1024
REPOSITORIES = ("dotnet/aspnetcore", "dotnet/maui", "dotnet/runtime", "dotnet/sdk")
IDENTITY = {
    "pipelineId": "BuildDefinitionId", "testName": "TestName", "arguments": "Arguments",
    "argumentHash": "ArgumentHash", "queue": "QueueName", "testRunName": "TestRunName",
    "workItemFriendlyName": "WorkItemFriendlyName", "outcome": "Outcome",
}
FILTER_LENGTHS = {
    "testName": (1, 2048), "arguments": (0, 8192), "argumentHash": (0, 512),
    "queue": (0, 512), "testRunName": (0, 2048), "workItemFriendlyName": (0, 2048),
    "errorContains": (1, 1024),
}


class Problem(Exception):
    def __init__(self, status, kind, detail):
        super().__init__(detail)
        self.status, self.kind, self.detail = status, kind, detail


def invalid(detail="The history request is invalid."):
    raise Problem(400, "invalid-request", detail)


def strict_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                invalid("Duplicate JSON keys are not permitted.")
            result[key] = value
        return result

    def constant(value):
        invalid("Non-finite JSON values are not permitted.")

    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)
    except (UnicodeDecodeError, ValueError, RecursionError):
        invalid("The request must contain valid UTF-8 JSON.")


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False).encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def validate_query(value):
    if type(value) is not dict or set(value) - {"buildIds", "projection", "outcome", "allOutcomes", "filters"}:
        invalid()
    if not {"buildIds", "projection"} <= value.keys():
        invalid("buildIds and projection are required.")
    if ("outcome" in value) == ("allOutcomes" in value):
        invalid("Specify exactly one of outcome or allOutcomes.")
    ids = value["buildIds"]
    if type(ids) is not list or not 1 <= len(ids) <= 200:
        invalid("Supply one to 200 explicit build IDs.")
    if any(type(bid) is not int or not 1 <= bid <= 2147483647 for bid in ids):
        invalid("Build IDs must be positive int32 values.")
    if len(set(ids)) != len(ids):
        invalid("Duplicate build IDs are not permitted.")
    if value["projection"] not in ("case", "methodBuilds"):
        invalid("Unknown projection.")
    outcome = value.get("outcome")
    if "outcome" in value and (type(outcome) is not str or not 1 <= len(outcome) <= 64):
        invalid("An exact nonempty outcome is required.")
    if "allOutcomes" in value and value["allOutcomes"] is not True:
        invalid("allOutcomes must be true.")
    if value["projection"] == "methodBuilds":
        if outcome != "Failed" or "filters" in value or "allOutcomes" in value:
            invalid("methodBuilds requires Failed and no filters property.")
    if "filters" in value:
        filters = value["filters"]
        if type(filters) is not dict or not filters:
            invalid("filters must be a nonempty object.")
        if set(filters) - (set(FILTER_LENGTHS) | {"pipelineId"}):
            invalid("Unknown filter.")
        for field, val in filters.items():
            if field == "pipelineId":
                if type(val) is not int or not 1 <= val <= 2147483647:
                    invalid("pipelineId must be a positive int32 value.")
            else:
                low, high = FILTER_LENGTHS[field]
                if type(val) is not str or not low <= len(val) <= high:
                    invalid("Invalid string filter length or type.")
    try:
        json.dumps(value, ensure_ascii=False).encode("utf-8")
    except UnicodeError:
        invalid("Invalid Unicode scalar value.")
    return {**value, "buildIds": sorted(ids)}


def problem_body(problem, request_id):
    return {"type": "urn:build-insights-history:problem:" + problem.kind,
            "title": problem.kind.replace("-", " ").capitalize(),
            "status": problem.status, "detail": problem.detail, "requestId": request_id}


def project_result(repository, query, history, started, completed):
    groups = []
    for group in history["groups"]:
        if query["projection"] == "methodBuilds":
            groups.append({"kind": "methodBuilds", "method": group["identity"]["Method"],
                           "matchingBuildIds": group["builds"]})
        else:
            refs = [{
                "buildId": ref["build"], "testRunId": ref["run"], "testResultId": ref["result"],
                "helixJobId": ref["helix_job"], "workItemId": ref["work_item_id"],
                "workItemName": ref["work_item_name"], "referenceVerification": "notChecked",
            } for ref in group["references"]]
            identity = {field: group["identity"][raw] for field, raw in IDENTITY.items()}
            if "outcome" in query and identity["outcome"] != query["outcome"]:
                raise ValueError("Source outcome does not match query")
            for field, value in query.get("filters", {}).items():
                if field != "errorContains" and identity[field] != value:
                    raise ValueError("Source identity does not match predicate")
            groups.append({"kind": "case", "identity": identity, "matchingBuildIds": group["builds"],
                           "references": refs, "hasUnreferencedObservations": group["has_unreferenced"]})
    if len(groups) > 500 or any(len(g.get("references", [])) > 250 for g in groups) or sum(
        len(g.get("references", [])) for g in groups
    ) > 2000:
        raise Problem(422, "query-too-broad", "The result exceeds the group or reference limit.")
    result = {
        "repository": repository, "query": query, "queryCompleteness": "complete",
        "dataCompleteness": "unknown", "snapshotConsistency": "notGuaranteed",
        "identityVerification": "notChecked",
        "referenceDetail": "caseReferences" if query["projection"] == "case" else "omittedByProjection",
        "queryStartedAt": started, "queryCompletedAt": completed, "groups": groups,
        "notObservedBuildIds": sorted(set(query["buildIds"]) - {
            bid for group in groups for bid in group["matchingBuildIds"]}),
    }
    if len(encode(result)) > MAX_RESPONSE:
        raise Problem(422, "query-too-broad", "The result exceeds the response byte limit.")
    return result
