#!/usr/bin/env python3

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


API_ROOT = "https://api.github.com/repos/dotnet/aspnetcore/issues"
MAX_COMMENT_PAGES = 10


def _request_json(url, opener=urlopen):
    request = Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "dotnet-aspnetcore-assess-issue-readiness",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="GET",
    )
    with opener(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def _write_json(path, value):
    content = json.dumps(value, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    temporary_path = path.with_suffix(f"{path.suffix}.tmp")
    temporary_path.write_bytes(content)
    temporary_path.replace(path)
    return hashlib.sha256(content).hexdigest()


def _validate_issue_response(issue, expected_number, allow_pull_request):
    if not isinstance(issue, dict):
        raise ValueError("GitHub issue response must be an object")
    if issue.get("number") != expected_number:
        raise ValueError("GitHub issue response number does not match the request")
    is_pull_request = "pull_request" in issue
    path_segment = "pull" if is_pull_request else "issues"
    expected_url = f"https://github.com/dotnet/aspnetcore/{path_segment}/{expected_number}"
    if issue.get("html_url") != expected_url:
        raise ValueError("GitHub issue response is not the canonical dotnet/aspnetcore issue")
    if issue.get("repository_url") != "https://api.github.com/repos/dotnet/aspnetcore":
        raise ValueError("GitHub issue response repository does not match dotnet/aspnetcore")
    if not allow_pull_request and is_pull_request:
        raise ValueError("the requested number is a pull request, not an issue")


def acquire_snapshot(issue_number, artifact_root, related_issues=(), opener=urlopen):
    if issue_number < 1:
        raise ValueError("issue number must be positive")
    if any(number < 1 for number in related_issues):
        raise ValueError("related issue numbers must be positive")

    artifact_root = Path(artifact_root)
    if not artifact_root.is_absolute():
        raise ValueError("artifact root must be absolute")
    repository_root = Path(__file__).resolve().parents[4]
    resolved_root = artifact_root.resolve()
    if (
        resolved_root == repository_root
        or resolved_root.is_relative_to(repository_root)
        or repository_root.is_relative_to(resolved_root)
    ):
        raise ValueError("artifact root must not overlap the repository")

    evidence_root = resolved_root / "evidence"
    evidence_root.mkdir(parents=True, exist_ok=True)
    files = []

    issue_url = f"{API_ROOT}/{issue_number}"
    issue = _request_json(issue_url, opener)
    _validate_issue_response(issue, issue_number, allow_pull_request=False)
    issue_path = evidence_root / "issue.json"
    files.append(
        {
            "path": "evidence/issue.json",
            "sha256": _write_json(issue_path, issue),
            "source": issue_url,
            "method": "GET",
        }
    )

    comments = []
    for page in range(1, MAX_COMMENT_PAGES + 1):
        comments_url = f"{issue_url}/comments?per_page=100&page={page}"
        page_comments = _request_json(comments_url, opener)
        if not isinstance(page_comments, list):
            raise ValueError("GitHub comments response must be an array")
        comments.extend(page_comments)
        if len(page_comments) < 100:
            break
    else:
        raise ValueError(f"comment snapshot exceeded {MAX_COMMENT_PAGES * 100} comments")

    comments_path = evidence_root / "comments.json"
    files.append(
        {
            "path": "evidence/comments.json",
            "sha256": _write_json(comments_path, comments),
            "source": f"{issue_url}/comments",
            "method": "GET",
        }
    )

    for related_issue in sorted(set(related_issues)):
        related_url = f"{API_ROOT}/{related_issue}"
        related = _request_json(related_url, opener)
        _validate_issue_response(related, related_issue, allow_pull_request=True)
        relative_path = f"evidence/related-{related_issue}.json"
        files.append(
            {
                "path": relative_path,
                "sha256": _write_json(resolved_root / relative_path, related),
                "source": related_url,
                "method": "GET",
            }
        )

    manifest = {
        "schema_version": "1.0",
        "source_repository": "dotnet/aspnetcore",
        "issue_number": issue_number,
        "input_mode": "public_get_snapshot",
        "authenticated": False,
        "retrieved_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "files": files,
    }
    manifest_path = evidence_root / "acquisition-manifest.json"
    _write_json(manifest_path, manifest)
    return manifest_path


def main():
    parser = argparse.ArgumentParser(
        description="Acquire an unauthenticated GET-only public dotnet/aspnetcore issue snapshot."
    )
    parser.add_argument("issue_number", type=int)
    parser.add_argument("artifact_root", type=Path)
    parser.add_argument("--related-issue", type=int, action="append", default=[])
    args = parser.parse_args()

    try:
        manifest_path = acquire_snapshot(
            args.issue_number,
            args.artifact_root,
            related_issues=args.related_issue,
        )
    except (HTTPError, URLError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ACQUISITION FAILED: {error}", file=sys.stderr)
        return 1

    print(manifest_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
