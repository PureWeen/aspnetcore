"""Opt-in method/build seam only; does not run or modify the quarantine scanner."""


def collect_method_builds(client, build_ids):
    return client.query("dotnet/aspnetcore", {
        "buildIds": list(build_ids), "projection": "methodBuilds", "outcome": "Failed",
    })


def project_methods(response, build_ids):
    """Project one caller-selected A/B subset into the existing count/builds shape."""
    if (response["repository"] != "dotnet/aspnetcore"
            or response["query"]["projection"] != "methodBuilds"
            or response["query"].get("outcome") != "Failed"):
        raise ValueError("ASP.NET method projection requires its Failed history response")
    selected = set(build_ids)
    if not selected <= set(response["query"]["buildIds"]):
        raise ValueError("Consumer subset is outside the queried build manifest")
    result = {}
    for group in response["groups"]:
        ids = sorted(selected.intersection(group["matchingBuildIds"]))
        if ids:
            result[group["method"]] = {"count": len(ids), "builds": ids}
    return result


def fallback_build_ids(response, verified_positive_build_ids=()):
    """Indexed membership is not verification; every unverified build stays eligible."""
    verified = set(verified_positive_build_ids)
    selected = set(response["query"]["buildIds"])
    if not verified <= selected:
        raise ValueError("Verified positives are outside the queried build manifest")
    return sorted(selected - verified)
