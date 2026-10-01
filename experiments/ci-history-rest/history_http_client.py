"""Shared stdlib loopback transport and response validation, without source access."""

import datetime
from pathlib import Path
import stat
import urllib.error
import urllib.parse
import urllib.request
import uuid

from history_http_common import (
    IDENTITY, MAX_REQUEST, MAX_RESPONSE, REPOSITORIES, Problem, encode, strict_json, validate_query,
)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_response(value, repository, query):
    if value.get("repository") != repository or value.get("query") != query:
        raise ValueError("HTTP history response scope differs from the accepted query")
    constants = {"queryCompleteness": "complete", "dataCompleteness": "unknown",
                 "snapshotConsistency": "notGuaranteed", "identityVerification": "notChecked",
                 "referenceDetail": "caseReferences" if query["projection"] == "case" else "omittedByProjection"}
    if any(value.get(k) != v for k, v in constants.items()):
        raise ValueError("HTTP history response completeness semantics changed")
    groups = value.get("groups")
    if type(groups) is not list or len(groups) > 500:
        raise ValueError("Invalid HTTP group array")
    seen, observed, total = set(), set(), 0
    for group in groups:
        ids = group["matchingBuildIds"]
        if (type(ids) is not list or not ids or ids != sorted(set(ids))
                or any(type(b) is not int for b in ids) or not set(ids) <= set(query["buildIds"])):
            raise ValueError("Invalid group build membership")
        observed.update(ids)
        if query["projection"] == "methodBuilds":
            if group["kind"] != "methodBuilds" or type(group["method"]) is not str or any(
                k in group for k in ("identity", "references", "hasUnreferencedObservations")
            ):
                raise ValueError("Invalid method group")
            key = group["method"]
        else:
            identity = group["identity"]
            if group["kind"] != "case" or not set(IDENTITY) <= identity.keys():
                raise ValueError("Incomplete case identity")
            if "outcome" in query and identity["outcome"] != query["outcome"]:
                raise ValueError("Mismatched outcome")
            for field in IDENTITY:
                item = identity[field]
                if field == "pipelineId":
                    if item is not None and (type(item) is not int or not 1 <= item <= 2147483647):
                        raise ValueError("Invalid pipeline identity")
                elif item is not None and type(item) is not str:
                    raise ValueError("Invalid raw string identity")
            for field, expected in query.get("filters", {}).items():
                if field != "errorContains" and identity[field] != expected:
                    raise ValueError("HTTP response lost an exact predicate")
            refs = group["references"]
            ref_fields = ("buildId", "testRunId", "testResultId", "helixJobId", "workItemId", "workItemName")
            if (type(refs) is not list or len(refs) > 250
                    or len({encode({k: r[k] for k in ref_fields}) for r in refs}) != len(refs)):
                raise ValueError("Invalid reference array")
            if type(group["hasUnreferencedObservations"]) is not bool or (
                not refs and not group["hasUnreferencedObservations"]
            ):
                raise ValueError("Invalid unreferenced-observation status")
            for ref in refs:
                if (type(ref["buildId"]) is not int or ref["buildId"] not in ids
                        or ref["referenceVerification"] != "notChecked"):
                    raise ValueError("Invalid reference membership/verification")
                for field in ("testRunId", "testResultId", "workItemId"):
                    num = ref[field]
                    if num is not None and (type(num) is not int or not 1 <= num <= 9007199254740991):
                        raise ValueError("Invalid reported numeric reference")
                for field in ("helixJobId", "workItemName"):
                    txt = ref[field]
                    if txt is not None and (type(txt) is not str or not txt):
                        raise ValueError("Invalid opaque reference")
                if all(ref[k] is None for k in ref_fields[1:]):
                    raise ValueError("Fabricated empty source reference")
            total += len(refs)
            key = encode({k: identity[k] for k in IDENTITY})
        if key in seen:
            raise ValueError("Duplicate response identity")
        seen.add(key)
    missing = value.get("notObservedBuildIds")
    if (type(missing) is not list or any(type(b) is not int for b in missing)
            or total > 2000 or missing != sorted(set(query["buildIds"]) - observed)):
        raise ValueError("Invalid reference cap or scope complement")
    a, b = [datetime.datetime.fromisoformat(value[k].replace("Z", "+00:00"))
            for k in ("queryStartedAt", "queryCompletedAt")]
    if a.tzinfo is None or b.tzinfo is None or b < a:
        raise ValueError("Invalid operation timestamps")


class HistoryClient:
    def __init__(self, base_url, token_file, *, output=None):
        parsed = urllib.parse.urlsplit(base_url)
        if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not parsed.port
                or parsed.username or parsed.password or parsed.query or parsed.fragment
                or parsed.path not in ("", "/")):
            raise ValueError("Only an explicit loopback HTTP origin is supported")
        self.base_url = base_url.rstrip("/")
        self.token_file = Path(token_file)
        self.output = Path(output) if output is not None else None
        self.receipts = []

    def query(self, repository, request):
        if repository not in REPOSITORIES:
            raise ValueError("Unsupported public repository")
        accepted = validate_query(request)
        mode = self.token_file.stat().st_mode
        if not stat.S_ISREG(mode) or mode & 0o077:
            raise ValueError("Token file must be private (0600)")
        payload = encode(request)
        if len(payload) > MAX_REQUEST:
            raise Problem(413, "request-too-large", "The request exceeds 64 KiB.")
        path = f"/v1/repositories/{repository}/test-history/query"
        req = urllib.request.Request(self.base_url + path, data=payload, method="POST", headers={
            "Authorization": "Bearer " + self.token_file.read_text().strip(),
            "Content-Type": "application/json",
        })
        # No environment proxy or redirect can turn this demo into a remote request.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)
        try:
            response = opener.open(req, timeout=35)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            status, headers = response.status, response.headers
            raw = response.read(MAX_RESPONSE + 1)
        if len(raw) > MAX_RESPONSE or headers.get("Cache-Control") != "no-store":
            raise ValueError("Invalid response size or cache semantics")
        request_id = headers.get("X-Request-ID")
        uuid.UUID(request_id)
        value = strict_json(raw)
        media = headers.get_content_type()
        if status != 200:
            if media != "application/problem+json" or value.get("requestId") != request_id or value.get("status") != status:
                raise ValueError("Malformed HTTP problem response")
            raise Problem(status, value["type"].rsplit(":", 1)[-1], value["detail"])
        if media != "application/json":
            raise ValueError("Unexpected response media type")
        validate_response(value, repository, accepted)
        self.receipts.append({"requestId": request_id, "status": status,
                              "request_bytes": len(payload), "response_bytes": len(raw)})
        if self.output is not None:
            folder = self.output / request_id
            folder.mkdir(parents=True, exist_ok=False)
            (folder / "request.json").write_bytes(payload)
            (folder / "response.json").write_bytes(raw)
        return value
