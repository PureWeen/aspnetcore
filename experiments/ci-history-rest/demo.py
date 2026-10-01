#!/usr/bin/env python3
"""One-shot JSON bridge: synthetic files -> real loopback HTTP -> validated JSON."""

import argparse
from pathlib import Path
import sys

from aspnet_adapter import collect_method_builds, fallback_build_ids, project_methods
from fixture_service import fixture_service
from history_http_common import Problem, encode, strict_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--query", type=Path, required=True)
    parser.add_argument("--aspnet-adapter", action="store_true",
                        help="Show count/builds membership and unknown/fallback boundaries.")
    args = parser.parse_args()
    try:
        fixture = strict_json(args.fixture.read_bytes())
        query = strict_json(args.query.read_bytes())
        with fixture_service(fixture) as client:
            if args.aspnet_adapter:
                if args.repository != "dotnet/aspnetcore" or set(query) != {"buildIds", "projection", "outcome"} or (
                    query["projection"] != "methodBuilds" or query["outcome"] != "Failed"
                ):
                    raise ValueError("ASP.NET adapter requires an unfiltered Failed methodBuilds query")
                response = collect_method_builds(client, query["buildIds"])
                result = {"methods": project_methods(response, query["buildIds"]),
                          "notObservedBuildIds": response["notObservedBuildIds"],
                          "requiresVerificationBuildIds": fallback_build_ids(response),
                          "dataCompleteness": response["dataCompleteness"]}
            else:
                result = client.query(args.repository, query)
        sys.stdout.buffer.write(encode(result) + b"\n")
    except (Problem, ValueError, OSError) as error:
        print(f"History unavailable: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
