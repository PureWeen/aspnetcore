#!/usr/bin/env python3
"""Trusted runner fixtures; no SDK restore, npm install, or PR execution."""
import json
import copy
import os
import pathlib
import runpy
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(os.environ.get("REVIEW_EXECUTION_TEST_ROOT", pathlib.Path(__file__).resolve().parents[1]))
SCRIPTS = ROOT / "scripts"

def _fixture_tools(checkout):
    def git(*args):
        return subprocess.check_output(["git", "-c", "core.longpaths=true", *args],
                                       cwd=checkout, stderr=subprocess.DEVNULL).decode().strip()
    def write(name, text):
        file = checkout / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
    return git, write


class ExecutionTests(unittest.TestCase):
    def test_supported_scope_and_bounds(self):
        text = (SCRIPTS / "review-execution.sh").read_text()
        for required in ("Microsoft.AspNetCore.Components.QuickGrid.Tests.csproj",
                         "src/Components/Web.JS/", "timeout --signal=TERM", "deadline="):
            self.assertTrue(required in text, required)
        self.assertFalse("BREAK_RESTORE" in text)

    def test_workflow_failure_does_not_skip_source_review(self):
        text = (ROOT.parents[1] / "workflows" / "pull-request-review.md").read_text()
        for required in ("needs: [freeze_pr_head, review_execution]",
                         "if: always() && needs.activation.result == 'success'",
                         "persist-credentials: false", "if: ${{ github.event.repository.fork == false }}"):
            self.assertTrue(required in text, required)

    def test_publication_preflight_survives_execution_job_failure(self):
        text = (ROOT.parents[1] / "workflows" / "pull-request-review.md").read_text()
        preflight = text.split("  verify_live_head:\n", 1)[1].split("pre-agent-steps:", 1)[0]
        self.assertTrue("if: always() && needs.agent.result == 'success' && needs.freeze_pr_head.result == 'success'" in preflight)

    def test_packer_execution_exclusions_are_actor_specific(self):
        text = (SCRIPTS / "prepare-review.cs").read_text()
        self.assertTrue("Hosted agent and workers executing PR code" in text)
        self.assertFalse('"Running PR code, tests, CI, browser workflows, or implementation samples"' in text)

    def test_artifact_normalizer_and_gate_fixtures(self):
        subprocess.run([sys.executable, str(SCRIPTS / "execution-evidence.py"), "--self-test"], check=True)

    def test_malformed_optional_artifacts_emit_parseable_unavailable_status(self):
        target = {"head": "a" * 40, "mergeBase": "b" * 40, "baseTip": "c" * 40}
        report = {"schemaVersion": 1, "headSha": target["head"], "mergeBaseSha": target["mergeBase"],
                  "baseTipSha": target["baseTip"], "classification": "not-applicable",
                  "changedFiles": [{"path": "README.md", "kind": "docs-only"}]}
        cases = [("integer schema", json.dumps(report), True),
                 ("numeric schema", json.dumps({**report, "schemaVersion": 1.0}), True),
                 ("boolean schema", json.dumps({**report, "schemaVersion": True}), False)]
        for constant in ("NaN", "Infinity", "-Infinity", "1e999"):
            cases.append((constant, json.dumps(report)[:-1] + ', "extra": ' + constant + "}", False))
        for depth in (900, 5000):
            cases.append(("nested extra " + str(depth),
                          json.dumps(report)[:-1] + ', "extra": ' + "[" * depth + "0" + "]" * depth + "}", False))
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            manifest, input_file, output_file = root / "manifest.json", root / "input.json", root / "execution.json"
            manifest.write_text(json.dumps({"target": target}))
            for label, text, available in cases:
                with self.subTest(label=label):
                    input_file.write_text(text)
                    subprocess.run([sys.executable, str(SCRIPTS / "execution-evidence.py"),
                                    str(input_file), str(manifest), str(output_file)], check=True)
                    parsed = subprocess.run(["node", "-e",
                                             "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))",
                                             str(output_file)], capture_output=True, text=True)
                    self.assertEqual(parsed.returncode, 0, parsed.stderr)
                    result = json.loads(output_file.read_text())
                    self.assertEqual(result["available"], available)
                    self.assertTrue(result["supportingEvidenceOnly"])
                    if not available:
                        self.assertEqual(result["classification"], "infra-failure")
                        self.assertTrue(result["reason"])
            input_file.write_text(json.dumps(report))
            output_file.unlink()
            manifest.write_text("{")
            required_failure = subprocess.run([sys.executable, str(SCRIPTS / "execution-evidence.py"),
                                               str(input_file), str(manifest), str(output_file)],
                                              capture_output=True, text=True)
            self.assertNotEqual(required_failure.returncode, 0)
            self.assertIn("JSONDecodeError", required_failure.stderr)
            self.assertFalse(output_file.exists())

    def test_public_summary_is_bound_deterministic_and_not_producer_text(self):
        target = {"head": "a" * 40, "mergeBase": "b" * 40, "baseTip": "c" * 40}
        base = {"schemaVersion": 1, "headSha": target["head"], "mergeBaseSha": target["mergeBase"],
                "baseTipSha": target["baseTip"], "classification": "not-applicable",
                "changedFiles": [{"kind": "docs-only"}], "publicSummary": "Invented producer commands.",
                "reason": "unavailable @mention `command` \u263a"}
        run_url = "https://github.com/PureWeen/aspnetcore/actions/runs/123"
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            manifest, input_file, output = root / "manifest.json", root / "input.json", root / "execution.json"
            manifest.write_text(json.dumps({"target": target}))
            for classification in ("not-applicable", "head-red", "red-compile", "zero-tests",
                                   "infra-failure", "unsupported", "mixed", "red-green", "green-green"):
                with self.subTest(classification=classification):
                    report = {**base, "classification": classification}
                    if classification in {"red-green", "green-green"}:
                        report.update(plan=[], results=[], revertedFiles=["src/Product.cs"], restoredHead=True)
                        for index, failure_kind in enumerate(("assertion", "test-body-exception")):
                            method = "Tests.Cases.Sample" + str(index)
                            report["plan"].append({"kind": "dotnet", "methods": [method]})
                            for tree in ("head", "reverted"):
                                failed = tree == "reverted" and classification == "red-green"
                                report["results"].append({
                                    "planIndex": index, "tree": tree, "kind": "dotnet",
                                    "passed": 0 if failed else 1, "failed": 1 if failed else 0,
                                    "total": 1, "skipped": 0, "exitCode": 1 if failed else 0,
                                    "classification": "fail" if failed else "pass", "reportFound": True,
                                    "preservedHeadInputs": True, "testCases": [{"name": method,
                                        "outcome": "Failed" if failed else "Passed", "failureKind": failure_kind}]})
                    input_file.write_text(json.dumps(report))
                    texts = []
                    for _ in range(2):
                        subprocess.run([sys.executable, str(SCRIPTS / "execution-evidence.py"),
                                        str(input_file), str(manifest), str(output)],
                                       env={**os.environ, "REVIEW_EXECUTION_RUN_URL": run_url}, check=True)
                        result = json.loads(output.read_text())
                        texts.append(result["publicSummary"])
                    self.assertEqual(texts[0], texts[1])
                    self.assertTrue(texts[0].startswith("Execution: " + classification + "\n"))
                    self.assertTrue(texts[0].isascii())
                    self.assertLessEqual(len(texts[0]), 2400)
                    for value in (*target.values(), run_url):
                        self.assertIn(value, texts[0])
                    for value in ("Invented producer", "@", "`"):
                        self.assertNotIn(value, texts[0])
                    self.assertIn("source findings are not execution-verified", texts[0])
                    if classification == "red-green":
                        self.assertIn("head 2 passed, 0 failed, 0 skipped", texts[0])
                        self.assertIn("1 assertions, 1 test-method-stack exceptions", texts[0])
                    elif classification not in {"green-green", "not-applicable"}:
                        self.assertNotIn("Recorded rows:", texts[0])
                    self.assertEqual(texts[0], (root / "execution-public-summary.txt").read_text())

    def test_normalizer_rejects_inconsistent_rows_and_inputs(self):
        normalize = runpy.run_path(str(SCRIPTS / "execution-evidence.py"))["normalize"]
        target = {"head": "a" * 40, "mergeBase": "b" * 40, "baseTip": "c" * 40}
        valid = {
            "schemaVersion": 1, "headSha": target["head"], "mergeBaseSha": target["mergeBase"],
            "baseTipSha": target["baseTip"], "classification": "red-green",
            "plan": [{"kind": "dotnet", "files": ["test.cs"], "methods": ["Tests.Cases.First"], "expectedRows": {"Tests.Cases.First": 2}}],
            "revertedFiles": ["src/Product.cs"], "unsupported": [], "restoredHead": True, "results": []
        }
        for tree in ("head", "reverted"):
            valid["results"].append({
                "planIndex": 0, "kind": "dotnet", "tree": tree, "passed": 2 if tree == "head" else 1,
                "failed": 0 if tree == "head" else 1, "skipped": 0, "total": 2,
                "exitCode": 0 if tree == "head" else 1, "reportFound": True, "preservedHeadInputs": True,
                "classification": "pass" if tree == "head" else "fail",
                "testCases": [
                    {"name": "Tests.Cases.First(value: 1)", "outcome": "Passed"},
                    {"name": "Tests.Cases.First(value: 2)", "outcome": "Passed" if tree == "head" else "Failed",
                     "failureKind": "assertion"}
                ]
            })
        self.assertTrue(normalize(valid, target)["available"])
        alterations = []
        for label, change in [
            ("timeout with partial failed report", {"exitCode": 124}),
            ("setup failure", {}),
            ("changed head inputs", {"preservedHeadInputs": False}),
            ("boolean plan identity", {"planIndex": False}),
            ("wrong parser", {"kind": "jest"}),
            ("contradictory row classification", {"classification": "pass"})
        ]:
            altered = copy.deepcopy(valid)
            altered["results"][1].update(change)
            if label == "setup failure":
                altered["results"][1]["testCases"][1]["failureKind"] = "setup-or-unclassified"
            alterations.append((label, altered))
        altered = copy.deepcopy(valid)
        for result in altered["results"]:
            result["testCases"][1]["name"] = result["testCases"][0]["name"]
        alterations.append(("duplicate row identities", altered))
        altered = copy.deepcopy(valid)
        for result in altered["results"]:
            result["total"] += 1
            result["skipped"] += 1
            result["testCases"].append({"name": "Tests.Cases.First(value: 3)", "outcome": "Unknown"})
        alterations.append(("unknown skipped outcome", altered))
        altered = copy.deepcopy(valid)
        altered["results"][0]["testCases"][1]["outcome"] = "NotExecuted"
        altered["results"][0].update(passed=1, skipped=1)
        alterations.append(("failing row never passed at head", altered))
        altered = copy.deepcopy(valid)
        for result in altered["results"]:
            result["testCases"] = result["testCases"][1:]
            result["total"] = 1
            result["passed"] -= 1
        alterations.append(("missing literal theory row", altered))
        for label, altered in alterations:
            with self.subTest(label=label):
                self.assertFalse(normalize(altered, target)["available"])

    def test_changed_selection_excludes_unrelated_tests_and_keeps_theory_rows(self):
        runner = (SCRIPTS / "review-execution.sh").read_text()
        report_code = runner.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            checkout, output = root / "checkout", root / "output"
            checkout.mkdir()
            output.mkdir()
            git, write = _fixture_tools(checkout)
            git("init", "-q")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            cs = "src/Components/QuickGrid/Microsoft.AspNetCore.Components.QuickGrid/test/"
            js = "src/Components/Web.JS/"
            write(cs + "Microsoft.AspNetCore.Components.QuickGrid.Tests.csproj", "<Project/>")
            original_cs = """namespace Tests;
public class Cases
{
    [Fact(Skip = "unchanged control")]
    public void Unchanged() { Assert.True(true); }
    [Theory]
    [InlineData(1)]
    public void Changed(int value) { Assert.True(value > 0); }
}
"""
            original_js = """describe('group', () => {
  test('unchanged', () => { expect(true).toBe(true); });
  test('changed', () => { expect(1).toBe(1); });
});
"""
            write(cs + "Cases.cs", original_cs)
            write(js + "test/Cases.test.ts", original_js)
            write(js + "package.json", json.dumps({"name": "@microsoft/microsoft.aspnetcore.components.web.js",
                                                  "scripts": {"test": "jest"}}))
            write("package.json", json.dumps({"workspaces": ["src/Components/Web.JS"]}))
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            cases = [
                ("theory data row", cs + "Cases.cs", original_cs.replace("[InlineData(1)]", "[InlineData(1)]\n    [InlineData(2)]"),
                 "dotnet", ["Tests.Cases.Changed"], {"Tests.Cases.Changed": 2}),
                ("new fact before skipped old control", cs + "Cases.cs",
                 original_cs.replace('    [Fact(Skip', '    [Fact]\n    public void NewRegression() { Assert.True(true); }\n    [Fact(Skip'),
                 "dotnet", ["Tests.Cases.NewRegression"], {"Tests.Cases.NewRegression": 1}),
                ("changed one-line body before unchanged theory", cs + "Cases.cs",
                 original_cs.replace("Assert.True(true)", "Assert.False(false)"),
                 "dotnet", ["Tests.Cases.Unchanged"], {"Tests.Cases.Unchanged": 1}),
                ("changed one-line body with intervening blank line", cs + "Cases.cs",
                 original_cs.replace("Assert.True(true); }\n", "Assert.False(false); }\n\n"),
                 "dotnet", ["Tests.Cases.Unchanged"], {"Tests.Cases.Unchanged": 1}),
                ("static Jest body", js + "test/Cases.test.ts", original_js.replace("expect(1)", "expect(2)"),
                 "jest", ["group changed"], None),
                ("skipped new Jest case", js + "test/Cases.test.ts",
                 original_js.replace("\n});", "\n  test.skip('new regression', () => { expect(false).toBe(true); });\n});"),
                 "jest", ["group new regression"], None)
            ]
            try:
                for label, name, content, kind, selected, rows in cases:
                    with self.subTest(label=label):
                        git("reset", "--hard", base)
                        write(name, content)
                        git("add", ".")
                        git("commit", "-qm", label)
                        head = git("rev-parse", "HEAD")
                        subprocess.run([sys.executable, "-c", report_code, str(output), str(checkout), head, base, "init"],
                                       check=True, env={**os.environ, "REVIEW_EXECUTION_BASE_TIP": base})
                        plan = json.loads((output / "execution.json").read_text())["plan"][0]
                        self.assertEqual(selected, plan.get("methods" if kind == "dotnet" else "names", []))
                        if kind == "dotnet":
                            self.assertEqual(rows, plan["expectedRows"])
                            self.assertEqual("FullyQualifiedName=" + selected[0], plan["filter"])
                        else:
                            self.assertEqual("^" + selected[0].replace(" ", "\\ ") + "$", plan["filter"])
            finally:
                git("reset", "--hard", base)

    def test_real_jest_producer_rejects_hook_timeout_skipped_and_swapped_rows(self):
        jest_cli = pathlib.Path(os.environ.get("REVIEW_EXECUTION_TEST_JEST_CLI", ROOT.parents[2] / "node_modules/jest/bin/jest.js"))
        self.assertTrue(jest_cli.exists(), "Restore the owning Web.JS workspace to run producer coverage.")
        runner = (SCRIPTS / "review-execution.sh").read_text()
        report_code = runner.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        normalize = runpy.run_path(str(SCRIPTS / "execution-evidence.py"))["normalize"]
        bash = r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else "/bin/bash"
        scenarios = [
            ("hook", "beforeAll(() => product.initialize()); test('body', () => expect(true).toBe(true));", "infra-failure"),
            ("timeout", "test('body', () => { if (!product.value) setInterval(() => {}, 1000); expect(product.value).toBe(true); });", "infra-failure"),
            ("swapped", "if (product.value) { test('A', () => expect(true).toBe(true)); test.skip('B', () => expect(false).toBe(true)); } else { test.skip('A', () => expect(true).toBe(true)); test('B', () => expect(product.value).toBe(true)); }", "fail"),
            ("new-skipped", "test('old control', () => expect(true).toBe(true));\ntest.skip('new regression', () => expect(false).toBe(true));", "zero-tests")
        ]
        for label, tests, expected in scenarios:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                root = pathlib.Path(temp)
                checkout, output = root / "checkout", root / "output"
                checkout.mkdir()
                output.mkdir()
                git, write = _fixture_tools(checkout)
                js = "src/Components/Web.JS/"
                git("init", "-q")
                git("config", "user.name", "Fixture")
                git("config", "user.email", "fixture@example.invalid")
                write("package.json", json.dumps({"workspaces": [js.rstrip("/")]}))
                write(js + "package.json", json.dumps({"name": "@microsoft/microsoft.aspnetcore.components.web.js",
                                                       "scripts": {"test": "jest"}}))
                write(js + "src/Feature.js", "module.exports = {value:false};")
                preamble = "const product = require('../src/Feature');\n"
                if label == "new-skipped":
                    write(js + "test/Cases.test.js", preamble + tests.split("\n")[0] + "\n")
                git("add", ".")
                git("commit", "-qm", "base")
                base = git("rev-parse", "HEAD")
                write(js + "src/Feature.js", "module.exports = {value:true, initialize:()=>{}};")
                write(js + "test/Cases.test.js", preamble + tests)
                git("add", ".")
                git("commit", "-qm", "head")
                head = git("rev-parse", "HEAD")
                env = {**os.environ, "REVIEW_EXECUTION_BASE_TIP": base, "PYTHONUTF8": "1"}
                def report(mode, *args):
                    subprocess.run([sys.executable, "-c", report_code, str(output), str(checkout), head, base, mode, *map(str, args)],
                                   env=env, check=True, stdout=subprocess.DEVNULL)
                    return json.loads((output / "execution.json").read_text())
                d = report("init")
                plan = d["plan"][0]
                write("jest.config.cjs", "module.exports = " + json.dumps({
                    "rootDir": str(checkout / js), "testMatch": ["**/*.test.js"],
                    "testEnvironment": "node", "transform": {}, "reporters": ["default"]
                }) + ";")
                for tree in ("head", "reverted"):
                    if tree == "reverted":
                        report("revert")
                        git("restore", "--source=" + base, "--staged", "--worktree", "--", js + "src/Feature.js")
                    filename = output / (tree + ".json")
                    command = ["node", str(jest_cli), "--config", str(checkout / "jest.config.cjs"),
                        "--runInBand", "--runTestsByPath", "test/Cases.test.js",
                        "--testNamePattern=" + plan.get("filter", ""), "--no-cache", "--json", "--outputFile=" + str(filename)]
                    result = subprocess.run([bash, "-c", 'timeout --signal=TERM --kill-after=2s 20s "$@"', "producer", *command],
                                            cwd=checkout / js, capture_output=True, text=True, encoding="utf-8", timeout=35)
                    self.assertTrue(filename.exists(), result.stderr)
                    parsed = report("test", "jest", tree, filename, result.returncode, 0)["results"][-1]
                    if tree == "head" and label in ("hook", "timeout"):
                        self.assertEqual("pass", parsed["classification"], result.stderr)
                    if tree == "reverted":
                        self.assertEqual(expected, parsed["classification"], result.stderr)
                        if label == "hook":
                            self.assertEqual(0, parsed.get("runtimeErrorSuites"))
                            self.assertTrue(all(c["failureKind"] == "setup-or-unclassified" for c in parsed["testCases"]))
                        if label == "timeout":
                            self.assertEqual(124, result.returncode)
                        if label == "new-skipped":
                            self.assertEqual(0, parsed["passed"])
                git("restore", "--source=" + head, "--staged", "--worktree", "--", js + "src/Feature.js")
                d = report("finish")
                self.assertFalse(normalize(d, {"head": head, "mergeBase": base, "baseTip": base})["available"])
                print("Real Jest producer:", label, "unavailable;", [(r["tree"], r["classification"], r["exitCode"]) for r in d["results"]])

    def test_fallback_file_boundaries_preserve_required_source_failures(self):
        scratch = ROOT.parents[2] / "artifacts" / "review-execution-fallback-fixtures"
        scratch.mkdir(parents=True, exist_ok=True)
        report, manifest, output = (scratch / n for n in ("input.json", "manifest.json", "execution.json"))
        target = {"head": "a" * 40, "mergeBase": "b" * 40, "baseTip": "c" * 40}
        manifest.write_text(json.dumps({"target": target}))
        command = [sys.executable, str(SCRIPTS / "execution-evidence.py"), str(report), str(manifest), str(output)]
        try:
            if report.exists():
                report.unlink()
            subprocess.run(command, check=True)
            result = json.loads(output.read_text())
            self.assertFalse(result["available"])
            self.assertEqual("execution artifact is missing; review_execution job result: unknown", result["reason"])
            subprocess.run(command, check=True, env={**os.environ, "REVIEW_EXECUTION_JOB_RESULT": "failure"})
            self.assertEqual("execution artifact is missing; review_execution job result: failure",
                             json.loads(output.read_text())["reason"])
            report.write_text("not json")
            subprocess.run(command, check=True)
            self.assertEqual("execution artifact is unreadable or malformed", json.loads(output.read_text())["reason"])
            report.write_text(json.dumps({"schemaVersion": 1, "headSha": "d" * 40}))
            subprocess.run(command, check=True)
            self.assertEqual("execution report headSha does not match the frozen source bundle",
                             json.loads(output.read_text())["reason"])
            manifest.write_text("not json")
            self.assertNotEqual(0, subprocess.run(command, stderr=subprocess.DEVNULL).returncode)
        finally:
            shutil.rmtree(scratch)

    def test_subprocess_deadline_records_timeout(self):
        runner = (SCRIPTS / "review-execution.sh").read_text()
        run_step = "run_step() {" + runner.split("run_step() {", 1)[1].split("\nfinish() {", 1)[0]
        bash = pathlib.Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else pathlib.Path("/bin/bash")
        scratch = ROOT.parents[2] / "artifacts" / "review-execution-timeout"
        scratch.mkdir(parents=True, exist_ok=True)
        # Exercise the real trusted command wrapper with an inert sleep, not PR code.
        code = """set -euo pipefail
output=artifacts/review-execution-timeout
mkdir -p "$output/logs"
deadline=$((SECONDS + 1))
report() { printf '%s\\n' "$*" > "$output/record.txt"; }
""" + run_step + """
run_step deadline head sleep 3
test "$step_code" = 124
grep -q 'sleep 3' "$output/record.txt"
"""
        try:
            subprocess.run([str(bash), "-c", code], cwd=ROOT.parents[2], check=True, timeout=15)
        finally:
            shutil.rmtree(scratch)

    def test_runner_planner_results_and_restoration(self):
        runner = (SCRIPTS / "review-execution.sh").read_text()
        report_code = runner.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        scratch = ROOT.parents[2] / "artifacts" / "review-execution-fixtures"
        scratch.mkdir(parents=True, exist_ok=True)
        def remove_readonly(function, path, error):
            os.chmod(path, stat.S_IWRITE)
            function(path)

        checkout, output = scratch / "checkout", scratch / "output"
        for path in (checkout, output):
            if path.exists():
                shutil.rmtree(path, onexc=remove_readonly)
            path.mkdir()

        git, write = _fixture_tools(checkout)

        git("init", "-q")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        git("config", "core.longpaths", "true")
        prefix = "src/Components/QuickGrid/Microsoft.AspNetCore.Components.QuickGrid/"
        write(prefix + "src/Deleted.cs", "old")
        write(prefix + "src/RenameMe.cs", "rename")
        write(prefix + "test/Microsoft.AspNetCore.Components.QuickGrid.Tests.csproj", "<Project/>")
        git("add", ".")
        git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        (checkout / (prefix + "src/Deleted.cs")).unlink()
        (checkout / (prefix + "src/RenameMe.cs")).rename(checkout / (prefix + "src/Renamed.cs"))
        write(prefix + "src/Added.cs", "new")
        write(prefix + "test/SampleTest.cs", "namespace Tests; public class SampleTest { [Fact] public void Example() {} }")
        write("src/Other/test/OtherTest.cs", "namespace Tests; public class OtherTest { [Fact] public void Example() {} }")
        write("src/Other/test/Other.Tests.csproj", "<Project/>")
        git("add", ".")
        git("commit", "-qm", "head")
        head = git("rev-parse", "HEAD")
        env = {**os.environ, "REVIEW_EXECUTION_BASE_TIP": base}

        def report(mode, *args):
            subprocess.run([sys.executable, "-c", report_code, str(output), str(checkout), head, base, mode, *map(str, args)],
                           env=env, check=True, stdout=subprocess.DEVNULL)
            return json.loads((output / "execution.json").read_text())

        try:
            d = report("init")
            self.assertEqual(1, len(d["plan"]))
            self.assertTrue(any(p["path"].startswith("src/Other/") for p in d["unsupported"]))
            with self.subTest(label="exact method filter"):
                self.assertEqual(["Tests.SampleTest.Example"], d["plan"][0].get("methods"))
                self.assertEqual("FullyQualifiedName=Tests.SampleTest.Example", d["plan"][0]["filter"])
            d = report("revert")
            self.assertEqual({prefix + "src/Added.cs", prefix + "src/Deleted.cs",
                             prefix + "src/RenameMe.cs", prefix + "src/Renamed.cs"}, set(d["revertedFiles"]))
            self.assertNotIn(prefix + "test/SampleTest.cs", d["revertedFiles"])
            check_inputs = [sys.executable, "-c", report_code, str(output), str(checkout), head, base, "check-inputs"]
            with self.subTest(label="unapplied product reversion"):
                self.assertNotEqual(0, subprocess.run([*check_inputs, "reverted"], env=env).returncode)
            for path in d["revertedFiles"]:
                if subprocess.run(["git", "cat-file", "-e", base + ":" + path], cwd=checkout, stderr=subprocess.DEVNULL).returncode == 0:
                    git("checkout", base, "--", path)
                else:
                    git("rm", "-f", "--", path)
            self.assertEqual("old", (checkout / (prefix + "src/Deleted.cs")).read_text())
            self.assertFalse((checkout / (prefix + "src/Added.cs")).exists())
            self.assertEqual("rename", (checkout / (prefix + "src/RenameMe.cs")).read_text())
            self.assertFalse((checkout / (prefix + "src/Renamed.cs")).exists())
            self.assertEqual(0, subprocess.run([*check_inputs, "reverted"], env=env).returncode)
            for path in d["revertedFiles"]:
                if subprocess.run(["git", "cat-file", "-e", head + ":" + path], cwd=checkout, stderr=subprocess.DEVNULL).returncode == 0:
                    git("checkout", head, "--", path)
                else:
                    git("rm", "-f", "--", path)
            self.assertEqual("", git("status", "--porcelain", "--untracked-files=no"))
            write(prefix + "test/SampleTest.cs", "changed preserved test input")
            with self.subTest(label="changed preserved tracked input"):
                self.assertNotEqual(0, subprocess.run([*check_inputs, "head"], env=env).returncode)
            git("restore", "--source=" + head, "--staged", "--worktree", "--", prefix + "test/SampleTest.cs")
            self.assertEqual(0, subprocess.run([*check_inputs, "head"], env=env).returncode)
            jest = output / "jest.json"
            for passed, failed, pending, runtime, expected in [
                (2, 0, 0, 0, "pass"), (1, 1, 0, 0, "fail"),
                (0, 0, 0, 0, "zero-tests"), (0, 0, 2, 0, "zero-tests"),
                (0, 0, 0, 1, "infra-failure")]:
                jest.write_text(json.dumps({"numTotalTests": passed + failed + pending, "numPassedTests": passed,
                                            "numFailedTests": failed, "numPendingTests": pending,
                                            "numRuntimeErrorTestSuites": runtime}))
                d = report("test", "jest", "head", jest, 1 if failed or runtime else 0, 0)
                self.assertEqual(expected, d["results"][-1]["classification"])
            for classification in ("head-red", "red-compile", "infra-failure", "zero-tests"):
                self.assertEqual(classification, report("failure", classification, "exact failure")["classification"])
            self.assertTrue(report("finish")["restoredHead"])
            d = report("init")
            report("revert")
            for tree, failed in (("head", 0), ("reverted", 1)):
                jest.write_text(json.dumps({"numTotalTests": 2, "numPassedTests": 2 - failed, "numFailedTests": failed}))
                report("test", "jest", tree, jest, failed, 0)
            self.assertEqual("mixed", report("finish")["classification"])
            # The measured planner must distinguish docs-only from unsupported product-only changes.
            git("reset", "--hard", base)
            write("docs/Example.md", "docs")
            git("add", ".")
            git("commit", "-qm", "docs")
            head = git("rev-parse", "HEAD")
            self.assertEqual("not-applicable", report("init")["classification"])
            git("reset", "--hard", base)
            write(".github/workflows/example.md", "---\non: push\n---\nExecutable workflow")
            git("add", ".")
            git("commit", "-qm", "workflow")
            head = git("rev-parse", "HEAD")
            self.assertEqual("unsupported", report("init")["classification"])
            git("reset", "--hard", base)
            write(prefix + "src/Value.cs", "product")
            git("add", ".")
            git("commit", "-qm", "product")
            head = git("rev-parse", "HEAD")
            self.assertEqual("unsupported", report("init")["classification"])
            git("reset", "--hard", base)
            write(prefix + "test/OnlyTest.cs", "namespace Tests; public class OnlyTest { [Fact] public void Example() {} }")
            git("add", ".")
            git("commit", "-qm", "test-only")
            head = git("rev-parse", "HEAD")
            report("init")
            report("revert")
            for tree, failed in (("head", 0), ("reverted", 1)):
                jest.write_text(json.dumps({"numTotalTests": 2, "numPassedTests": 2 - failed, "numFailedTests": failed}))
                report("test", "jest", tree, jest, failed, 0)
            self.assertEqual("infra-failure", report("finish")["classification"])
            report("init")
            for message, code, expected, failure_kind in [
                ("Error: database unavailable\n    at _callCircusHook (jest/run.js:1:1)", 1, "infra-failure", "setup-or-unclassified"),
                ("Error: expect(received).toBe(expected)\n    at _callCircusTest (jest/run.js:1:1)", 1, "fail", "assertion"),
                ("Error: expect(received).toBe(expected)\n    at _callCircusTest (jest/run.js:1:1)", 124, "infra-failure", "assertion"),
                ("TypeError: product unavailable\n    at _callCircusTest (jest/run.js:1:1)", 1, "fail", "test-body-exception"),
                ("Error: expect(received).toBe(expected)\n    at _callCircusHook (jest/run.js:1:1)", 1, "infra-failure", "setup-or-unclassified")
            ]:
                with self.subTest(message=message, exit_code=code):
                    jest.write_text(json.dumps({
                        "numTotalTests": 1, "numPassedTests": 0, "numFailedTests": 1,
                        "testResults": [{"assertionResults": [{
                            "fullName": "body", "status": "failed", "failureMessages": [message]
                        }]}]
                    }))
                    result = report("test", "jest", "reverted", jest, code, 0)["results"][-1]
                    self.assertEqual((expected, failure_kind), (result["classification"], result["testCases"][0].get("failureKind")))
        finally:
            shutil.rmtree(scratch, onexc=remove_readonly)


if __name__ == "__main__":
    unittest.main()
