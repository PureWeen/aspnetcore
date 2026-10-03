#!/usr/bin/env python3
"""Trusted runner fixtures; no SDK restore, npm install, or PR execution."""
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import textwrap
import unittest

ROOT = pathlib.Path(os.environ.get("REVIEW_EXECUTION_TEST_ROOT", pathlib.Path(__file__).resolve().parents[1]))
SCRIPTS = ROOT / "scripts"


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

    def test_packer_execution_exclusions_are_actor_specific(self):
        text = (SCRIPTS / "prepare-review.cs").read_text()
        self.assertTrue("Hosted agent and workers executing PR code" in text)
        self.assertFalse('"Running PR code, tests, CI, browser workflows, or implementation samples"' in text)

    def test_artifact_normalizer_and_gate_fixtures(self):
        subprocess.run([sys.executable, str(SCRIPTS / "execution-evidence.py"), "--self-test"], check=True)

    def test_publication_gate_shapes(self):
        text = (ROOT.parents[1] / "workflows" / "pull-request-review.md").read_text()
        section = text.split("- name: Reject incomplete or partial publication sets", 1)[1]
        code = textwrap.dedent(section.split("script: |\n", 1)[1].split("      - name:", 1)[0])
        wrapper = """
const vm = require('vm');
const code = JSON.parse(process.argv[1]);
const unavailable = {available:false, classification:'infra-failure', reason:'restore failed'};
const available = {available:true, classification:'red-green', reason:'paired results'};
const fixed = 'Review completed source-only with no new findings; execution evidence unavailable (infra-failure): restore failed';
const cases = [
  [unavailable, [{type:'add_comment',body:fixed}], true],
  [unavailable, [{type:'noop'}], false],
  [available, [{type:'noop'}], true],
  [unavailable, [{type:'add_comment',body:fixed},{type:'noop'}], false],
  [unavailable, [{type:'add_comment',body:fixed+'\\nextra'}], false],
  [unavailable, [{type:'add_comment',body:fixed.replace('restore failed','invented')}], false],
  [available, [{type:'add_comment',body:fixed}], false],
  [unavailable, [{type:'create_pull_request_review_comment'},
    {type:'submit_pull_request_review',body:'Execution: infra-failure; restore failed'}], true],
  [unavailable, [{type:'create_pull_request_review_comment'},
    {type:'submit_pull_request_review',body:'no execution section'}], false],
  [available, [{type:'create_pull_request_review_comment'}], false],
  [available, [], false],
  [available, [{type:'add_comment',body:'arbitrary text'}], false],
  [available, [{type:'noop'},{type:'unsupported_public_shape'}], false],
  [unavailable, [{type:'report_incomplete',reason:'missing guide'},
    {type:'add_comment',body:'Review not published (INCOMPLETE): missing guide\\n\\nNo partial findings were published.'}], true],
];
const mismatches = [];
for (const [index, [execution, items, expected]] of cases.entries()) {
  let failed=false;
  const fs={readFileSync: filename => JSON.stringify(filename.endsWith('agent_output.json') ? {items} : execution)};
  vm.runInNewContext('(function(){'+code+'})()', {require:n=>n==='fs'?fs:require(n),
    process:{env:{RUNNER_TEMP:'.'}},core:{setFailed:()=>{failed=true;}}});
  if ((!failed)!==expected) mismatches.push({index,items,expected,failed});
}
if (mismatches.length) throw new Error(JSON.stringify(mismatches));
console.log('Publication gate: '+cases.length+' allowed/rejected shape fixtures passed');
"""
        subprocess.run(["node", "-e", wrapper, json.dumps(code)], check=True)

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
            self.assertEqual("execution artifact is missing; job may have failed or timed out", result["reason"])
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

        def git(*args):
            return subprocess.check_output(["git", "-c", "core.longpaths=true", *args],
                                           cwd=checkout, stderr=subprocess.DEVNULL).decode().strip()

        def write(name, text):
            p = checkout / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)

        git("init", "-q")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        git("config", "core.longpaths", "true")
        prefix = "src/Components/QuickGrid/Microsoft.AspNetCore.Components.QuickGrid/"
        write(prefix + "src/Deleted.cs", "old")
        write(prefix + "test/Microsoft.AspNetCore.Components.QuickGrid.Tests.csproj", "<Project/>")
        git("add", ".")
        git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        (checkout / (prefix + "src/Deleted.cs")).unlink()
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
            self.assertEqual(["Tests.SampleTest"], d["plan"][0]["classes"])
            d = report("revert")
            self.assertEqual({prefix + "src/Added.cs", prefix + "src/Deleted.cs"}, set(d["revertedFiles"]))
            self.assertNotIn(prefix + "test/SampleTest.cs", d["revertedFiles"])
            for path in d["revertedFiles"]:
                if subprocess.run(["git", "cat-file", "-e", base + ":" + path], cwd=checkout, stderr=subprocess.DEVNULL).returncode == 0:
                    git("checkout", base, "--", path)
                else:
                    git("rm", "-f", "--", path)
            self.assertEqual("old", (checkout / (prefix + "src/Deleted.cs")).read_text())
            self.assertFalse((checkout / (prefix + "src/Added.cs")).exists())
            for path in d["revertedFiles"]:
                if subprocess.run(["git", "cat-file", "-e", head + ":" + path], cwd=checkout, stderr=subprocess.DEVNULL).returncode == 0:
                    git("checkout", head, "--", path)
                else:
                    git("rm", "-f", "--", path)
            self.assertEqual("", git("status", "--porcelain", "--untracked-files=no"))
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
        finally:
            shutil.rmtree(scratch, onexc=remove_readonly)


if __name__ == "__main__":
    unittest.main()
