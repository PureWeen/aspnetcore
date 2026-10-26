"""Trusted profiles and exact command contract shared by execution and ingestion."""

ROOT = "/var/lib/review-build-sandbox"
PROFILES = ({
    "id": "response-caching",
    "changed_root": "src/Middleware/ResponseCaching/",
    "project": "src/Middleware/ResponseCaching/test/Microsoft.AspNetCore.ResponseCaching.Tests.csproj",
    "assembly": "Microsoft.AspNetCore.ResponseCaching.Tests",
},)


def commands(profile):
    common = [
        "bash", "./eng/build.sh", "--projects", ROOT + "/work/" + profile["project"],
        "--configuration", "Debug", "--no-build-native", "--no-build-nodejs",
        "--no-build-java", "--no-build-installers", "--msbuildMultiThreaded", "false",
    ]
    return {
        "bootstrap": ["bash", "-c", "source ./activate.sh && bash ./eng/common/dotnet.sh --info"],
        "sdk": ["bash", "-c", "source ./activate.sh && dotnet --version"],
        "restore": common + ["--restore", "--no-build", "--no-test"],
        "build": common + ["--no-restore", "--build", "--no-test"],
        "test": common + ["--no-restore", "--no-build", "--test"],
    }
