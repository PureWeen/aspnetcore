"""NEW fixture-only harness, not the historical live/replay service or backend."""

from contextlib import contextmanager
import datetime
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import secrets
import tempfile
import threading
import uuid

from history_http_client import HistoryClient
from history_http_common import (
    CONTRACT_SHA256, IDENTITY, MAX_REQUEST, REPOSITORIES, Problem, digest, encode,
    problem_body, project_result, strict_json, validate_query,
)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def number(value, maximum, nullable=False):
    if value is None and nullable:
        return value
    if type(value) is not int or not 1 <= value <= maximum:
        raise ValueError("Malformed reported numeric identity")
    return value


def text(value, empty_missing=False):
    if value is not None and type(value) is not str:
        raise ValueError("Malformed reported string identity")
    return None if empty_missing and value == "" else value


def group_reported(rows, scope_ids):
    """The spike's reported grouping, with only its serialization dependency removed."""
    groups = {}
    for row in rows:
        identity = {field: row[field] for field in IDENTITY.values()}
        for field, value in identity.items():
            if field == "BuildDefinitionId":
                number(value, 2147483647, nullable=True)
            else:
                text(value)
        bid = number(row["BuildId"], 2147483647)
        if bid not in scope_ids:
            raise ValueError("Reported row outside scope")
        reference = {
            "build": bid,
            "run": number(row["TestRunId"], 9007199254740991, nullable=True),
            "result": number(row["TestResultId"], 9007199254740991, nullable=True),
            "helix_job": text(row["JobName"], empty_missing=True),
            "work_item_id": number(row["WorkItemId"], 9007199254740991, nullable=True),
            "work_item_name": text(row["WorkItemName"], empty_missing=True),
        }
        group = groups.setdefault(encode(identity), {
            "identity": identity, "builds": set(), "references": {}, "has_unreferenced": False,
        })
        group["builds"].add(bid)
        if any(value is not None for name, value in reference.items() if name != "build"):
            group["references"][encode(reference)] = reference
        else:
            group["has_unreferenced"] = True
    return {"groups": [
        {**group, "builds": sorted(group["builds"]),
         "references": [ref for _, ref in sorted(group["references"].items())]}
        for _, group in sorted(groups.items())
    ]}


def fixture_result(fixture, repository, query):
    started = now()
    builds = fixture["builds"]
    for bid in query["buildIds"]:
        matches = [b for b in builds if b["id"] == bid]
        if len(matches) != 1 or matches[0]["repository"]["id"] != repository or matches[0]["project"]["name"] != "public":
            raise Problem(404, "scope-not-found", "The requested scope is unavailable.")
        number(matches[0]["id"], 2147483647)
        number(matches[0]["definition"]["id"], 2147483647)
    fault = fixture.get("fault", {}).get("kind")
    if fault:
        status, kind = {
            "partial": (502, "source-incomplete"),
            "invalid": (502, "source-invalid"),
            "unavailable": (503, "dependency-unavailable"),
        }[fault]
        raise Problem(status, kind, "Synthetic source failure; no history result is available.")
    selected = []
    for row in fixture["rows"]:
        bid = number(row["BuildId"], 2147483647)
        if bid not in query["buildIds"]:
            continue
        # A missing source column is not the same as an explicitly reported null.
        for field in IDENTITY.values():
            value = row[field]
            if field == "BuildDefinitionId":
                number(value, 2147483647, nullable=True)
            else:
                text(value)
        if "outcome" in query and row["Outcome"] != query["outcome"]:
            continue
        if any(row[IDENTITY[k]] != v for k, v in query.get("filters", {}).items() if k != "errorContains"):
            continue
        if "errorContains" in query.get("filters", {}):
            message = text(row["Message"])
            if message is None or query["filters"]["errorContains"] not in message:
                continue
        selected.append(row)
    if query["projection"] == "methodBuilds":
        methods = {}
        for row in selected:
            name = row["TestName"]
            method = "" if name is None else name.split("(")[0].strip()
            methods.setdefault(method, set()).add(row["BuildId"])
        history = {"groups": [{"identity": {"Method": method}, "builds": sorted(ids)}
                              for method, ids in sorted(methods.items())]}
    else:
        history = group_reported(selected, query["buildIds"])
    return project_result(repository, query, history, started, now())


class FixtureServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def __init__(self, fixture, token):
        self.fixture, self.token = fixture, token
        super().__init__(("127.0.0.1", 0), Handler)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def operation(self):
        request_id = str(uuid.uuid4())
        self.close_connection = True
        self.connection.settimeout(2)
        try:
            auth = self.headers.get_all("Authorization", [])
            if len(auth) != 1 or not auth[0].isascii() or not hmac.compare_digest(auth[0], "Bearer " + self.server.token):
                raise Problem(401, "unauthorized", "An ephemeral local test token is required.")
            if not self.server.fixture.get("admitted", True):
                raise Problem(403, "not-admitted", "The synthetic principal is not admitted.")
            match = re.fullmatch(r"/v1/repositories/(dotnet)/(aspnetcore|maui|runtime|sdk)/test-history/query", self.path)
            if match is None:
                raise Problem(404, "scope-not-found", "The requested scope is unavailable.")
            repository = "/".join(match.groups())
            if repository not in self.server.fixture.get("repositories", REPOSITORIES):
                raise Problem(404, "scope-not-found", "The requested scope is unavailable.")
            if self.command != "POST":
                raise Problem(405, "method-not-allowed", "Only POST is supported.")
            if self.headers.get_content_type() != "application/json":
                raise Problem(415, "unsupported-media-type", "application/json is required.")
            lengths = self.headers.get_all("Content-Length", [])
            if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or not re.fullmatch(r"[0-9]+", lengths[0]):
                raise Problem(400, "invalid-request", "An unambiguous Content-Length is required.")
            length = int(lengths[0])
            if length > MAX_REQUEST:
                raise Problem(413, "request-too-large", "The request exceeds 64 KiB.")
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise Problem(400, "invalid-request", "Incomplete request body.")
            query = validate_query(strict_json(raw))
            payload = encode(fixture_result(self.server.fixture, repository, query))
            status, media = 200, "application/json"
        except (Problem, ValueError, KeyError, TypeError, TimeoutError) as error:
            if isinstance(error, Problem):
                problem = error
            elif isinstance(error, TimeoutError):
                problem = Problem(504, "query-deadline", "The local request read timed out.")
            else:
                problem = Problem(502, "source-invalid", "Synthetic source data failed validation.")
            status, media = problem.status, "application/problem+json"
            payload = encode(problem_body(problem, request_id))
        self.send_response(status)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Request-ID", request_id)
        self.send_header("Connection", "close")
        if status == 401:
            self.send_header("WWW-Authenticate", "Bearer")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    do_POST = do_GET = do_PUT = do_DELETE = do_HEAD = do_PATCH = do_OPTIONS = do_TRACE = operation


@contextmanager
def fixture_service(fixture):
    """Yield a shared client using an owned listener and temporary test credential."""
    contract = Path(__file__).with_name("openapi.json").read_bytes()
    if digest(contract) != CONTRACT_SHA256:
        raise ValueError("Approved contract bytes changed")
    snapshot = strict_json(encode(fixture))
    with tempfile.TemporaryDirectory(prefix="ci-history-demo-") as directory:
        token_file = Path(directory) / "token"
        token = secrets.token_urlsafe(32)
        token_file.touch(mode=0o600)
        token_file.write_text(token)
        server = FixtureServer(snapshot, token)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
        thread.start()
        try:
            yield HistoryClient(f"http://127.0.0.1:{server.server_port}", token_file)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
