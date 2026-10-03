#!/usr/bin/env python3
"""Trusted runner fixtures; no SDK restore, npm install, or PR execution."""
import json
import os
import pathlib
import shutil
import stat
import subprocess
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"


class ExecutionTests(unittest.TestCase):
    def test_supported_scope_and_bounds(self):
        text = (SCRIPTS / "review-execution.sh").read_text()
        self.assertIn("Microsoft.AspNetCore.Components.QuickGrid.Tests.csproj", text)
        self.assertIn("src/Components/Web.JS/", text)
        self.assertIn("timeout --signal=TERM", text)
        self.assertIn("deadline=", text)
        self.assertNotIn("BREAK_RESTORE", text)

    def test_workflow_failure_does_not_skip_source_review(self):
        text = (ROOT.parents[1] / "workflows" / "pull-request-review.md").read_text()
        self.assertIn("needs: [freeze_pr_head, review_execution]", text)
        self.assertIn("if: always() && needs.activation.result == 'success'", text)
        self.assertIn("persist-credentials: false", text)
        self.assertIn("if: ${{ github.event.repository.fork == false }}", text)

    def test_packer_execution_exclusions_are_actor_specific(self):
        text = (SCRIPTS / "prepare-review.cs").read_text()
        self.assertIn("Hosted agent and workers executing PR code", text)
        self.assertNotIn('"Running PR code, tests, CI, browser workflows, or implementation samples"', text)

    def test_artifact_normalizer_and_gate_fixtures(self):
        subprocess.run(["python", str(SCRIPTS / "execution-evidence.py"), "--self-test"], check=True)

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
  [unavailable, [{type:'report_incomplete',reason:'missing guide'},
    {type:'add_comment',body:'Review not published (INCOMPLETE): missing guide\\n\\nNo partial findings were published.'}], true],
];
for (const [execution, items, expected] of cases) {
  let failed=false;
  const fs={readFileSync: filename => JSON.stringify(filename.endsWith('agent_output.json') ? {items} : execution)};
  vm.runInNewContext('(function(){'+code+'})()', {require:n=>n==='fs'?fs:require(n),
    process:{env:{RUNNER_TEMP:'.'}},core:{setFailed:()=>{failed=true;}}});
  if ((!failed)!==expected) throw new Error(JSON.stringify({items,expected,failed}));
}
console.log('Publication gate: 11 allowed/rejected shape fixtures passed');
"""
        subprocess.run(["node", "-e", wrapper, json.dumps(code)], check=True)

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
            return subprocess.check_output(["git", *args], cwd=checkout, stderr=subprocess.DEVNULL).decode().strip()

        def write(name, text):
            p = checkout / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)

        git("init", "-q")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
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
            subprocess.run(["python", "-c", report_code, str(output), str(checkout), head, base, mode, *map(str, args)],
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
            for tree, failed in (("head", 0), ("reverted", 1)):
                jest.write_text(json.dumps({"numTotalTests": 2, "numPassedTests": 2 - failed, "numFailedTests": failed}))
                report("test", "jest", tree, jest, failed, 0)
            self.assertEqual("mixed", report("finish")["classification"])
        finally:
            shutil.rmtree(scratch, onexc=remove_readonly)


if __name__ == "__main__":
    unittest.main()
