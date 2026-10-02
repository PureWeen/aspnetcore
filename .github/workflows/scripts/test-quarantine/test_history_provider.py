#!/usr/bin/env python3

import ast
import contextlib
import copy
import hashlib
import io
import json
import pathlib
import sys
import textwrap
import unittest


WORKFLOW = pathlib.Path(__file__).resolve().parents[2] / "test-quarantine.md"
ORIGINAL_AGGREGATE_AST = "c38b17aeb1594dd004c6481237ee37abe7743b81159e0da29ab2034c019d9602"
SOURCES = {
    "source_a": [1597399, 1576238, 1569345],
    "source_b": [1602497, 1599840],
}


def load_collector():
    text = WORKFLOW.read_text()
    block = text.split("    - name: Aggregate Part 1 failures\n", 1)[1]
    block = block.split("    - name: Check out trusted source history", 1)[0]
    script = textwrap.dedent(
        block.split("        python3 << 'SCRIPT'\n", 1)[1].rsplit("        SCRIPT\n", 1)[0]
    )
    wanted = {
        "norm_name", "aggregate_results", "none_history_provider", "aggregate",
        "mark_intermittency", "TestHistoryUnavailable",
    }
    definitions = []
    for node in ast.parse(script).body:
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in wanted:
            definitions.append(node)
        elif isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id in ("OCC_CAP", "WI_SUFFIX")
            for target in node.targets
        ):
            definitions.append(node)
    namespace = {"sys": sys}
    exec(compile(ast.Module(body=definitions, type_ignores=[]), str(WORKFLOW), "exec"), namespace)
    assert wanted <= namespace.keys()
    original = copy.deepcopy(next(
        node for node in definitions
        if isinstance(node, ast.FunctionDef) and node.name == "aggregate_results"
    ))
    original.name = "aggregate"
    assert hashlib.sha256(ast.dump(original, include_attributes=False).encode()).hexdigest() == ORIGINAL_AGGREGATE_AST
    return namespace


def result(name, result_id=1, run_id=10, assembly="Sample.Tests.dll"):
    return {
        "automatedTestName": name, "testCaseTitle": name,
        "automatedTestStorage": assembly, "id": result_id, "runId": run_id,
    }


def sample_pages():
    # Synthetic consumer-shape records patterned on five public AzDO builds.
    return {
        1597399: [
            result("Sample.TemplateTests.AddCredentials"),
            result("sample_batch.WorkItemExecution", 2, 11, "sample_batch"),
        ],
        1576238: [
            result("Sample.TemplateTests.Reauthenticate"),
            result("Sample.TemplateTests.UsePasskeys", 2),
            result("Sample.TemplateTests.ConfirmEmail", 3),
        ],
        1569345: [
            result("Sample.Http3Tests.Cancel", 1),
            result("Sample.Http3Tests.Cancel", 2),
            result("Sample.Http3Tests.Cancel", 3),
        ],
        1602497: [
            result("Sample.NavigationTests.BlockExternal"),
            result("Sample.VirtualizationTests.Append", 2),
            result("Sample.VirtualizationTests.Prepend", 3),
            result("Sample.PrerenderingTests.Lock", 4),
            result("Sample.ServerRoutingTests.BlockExternal", 5),
            result("Sample.NavigationTests.BlockExternal", 6),
        ],
        1599840: [],
    }


def membership(collector, pages):
    return {
        bid: {collector["norm_name"](row) for row in rows} - {""}
        for bid, rows in pages.items()
    }


def recurring_pages():
    pages = sample_pages()
    for index, bid in enumerate(SOURCES["source_a"]):
        pages[bid] = [
            result("Sample.RecurringTests.First", 1, 20 + index),
            result("Sample.RecurringTests.Second", 2, 20 + index),
        ]
    return pages


def compare(pages, history=None):
    collector = load_collector()
    reads = []

    def failed_results(bid):
        reads.append(bid)
        return iter(copy.deepcopy(pages[bid]))

    collector["failed_results"] = failed_results
    baseline = {
        source: collector["aggregate_results"](ids) for source, ids in SOURCES.items()
    }
    original_reads = list(reads)
    reads.clear()
    events = []

    def provider(bid):
        events.append(("provider", bid))
        value = history[bid]
        if isinstance(value, Exception):
            raise value
        return value

    error = io.StringIO()
    with contextlib.redirect_stderr(error):
        candidate = {
            source: (
                collector["aggregate"](ids) if history is None
                else collector["aggregate"](ids, history_provider=provider)
            )
            for source, ids in SOURCES.items()
        }
    timeline = [
        {"id": bid, "definition": {"id": 83}, "result": "partiallySucceeded",
         "startTime": f"2026-09-{30 - index:02d}T00:00:00Z"}
        for index, bid in enumerate(SOURCES["source_a"])
    ]
    bmeta = {
        str(build["id"]): {"def": 83, "startedUtc": build["startTime"]}
        for build in timeline
    }
    for output in (baseline, candidate):
        collector["mark_intermittency"](output["source_a"], timeline, bmeta)
    return baseline, candidate, original_reads, reads, error.getvalue(), events


class HistoryProviderTests(unittest.TestCase):
    def assert_same_answer(self, baseline, candidate):
        self.assertEqual(
            json.dumps(baseline, separators=(",", ":")),
            json.dumps(candidate, separators=(",", ":")),
        )
        for source in candidate.values():
            for entry in source.values():
                self.assertEqual(entry["count"], len(entry["builds"]))
                self.assertEqual(entry["count"], len(set(entry["builds"])))
                self.assertLessEqual(len(entry["occ"]), 2)

    def test_none_is_byte_identical_and_reads_every_page_once(self):
        baseline, candidate, original_reads, reads, error, _ = compare(sample_pages())
        self.assert_same_answer(baseline, candidate)
        self.assertEqual(reads, original_reads)
        self.assertEqual(len(reads), 5)
        self.assertEqual(error, "")

    def test_five_build_known_sample_has_exact_parity_and_zero_bypass(self):
        pages = sample_pages()
        history = membership(load_collector(), pages)
        baseline, candidate, original_reads, reads, error, events = compare(pages, history)
        self.assert_same_answer(baseline, candidate)
        self.assertEqual(reads, original_reads)
        self.assertEqual(sum(e["count"] for src in candidate.values() for e in src.values()), 11)
        self.assertEqual(error, "")
        self.assertEqual(events, [("provider", bid) for ids in SOURCES.values() for bid in ids])

    def test_normalization_deduplication_title_fallback_and_empty_name(self):
        pages = sample_pages()
        history = membership(load_collector(), pages)
        row = pages[1576238][0]
        name = row["automatedTestName"]
        row["automatedTestName"] = " \t" + name + '(value: "(")\n'
        pages[1576238].append(result(name + "(value: 2)", 4))
        row = pages[1576238][1]
        row["automatedTestName"] = ""
        row["testCaseTitle"] = "  Sample.TemplateTests.UsePasskeys(value: 3) "
        pages[1576238].append(result("", 5))
        baseline, candidate, *_ = compare(pages, history)
        self.assert_same_answer(baseline, candidate)
        original, *_ = compare(sample_pages())
        self.assertEqual(candidate, original)

    def test_missing_index_build_is_unknown_and_uses_original_pages(self):
        pages = sample_pages()
        history = membership(load_collector(), pages)
        history[1576238] = None
        baseline, candidate, original_reads, reads, *_ = compare(pages, history)
        self.assert_same_answer(baseline, candidate)
        self.assertEqual(reads, original_reads)

    def test_partial_representative_mismatch_replays_unmodified_aggregate(self):
        pages = sample_pages()
        history = membership(load_collector(), pages)
        history[1576238].remove("Sample.TemplateTests.ConfirmEmail")
        baseline, candidate, _, reads, error, _ = compare(pages, history)
        self.assert_same_answer(baseline, candidate)
        self.assertIn("test history mismatch for build 1576238", error)
        self.assertEqual(reads[:5], [1597399, 1576238, *SOURCES["source_a"]])

    def test_complete_recurrence_preserves_both_occ_slots_and_skips_older_page(self):
        pages = recurring_pages()
        baseline, candidate, _, reads, *_ = compare(pages, membership(load_collector(), pages))
        self.assert_same_answer(baseline, candidate)
        self.assertNotIn(1569345, reads)
        for record in candidate["source_a"].values():
            self.assertEqual(record["count"], 3)
            self.assertEqual(record["builds"], SOURCES["source_a"])
            self.assertEqual([occ["build"] for occ in record["occ"]], SOURCES["source_a"][:2])
            self.assertTrue(record["is_consistent_regression"])

    def test_missing_first_row_ids_does_not_use_later_duplicate(self):
        pages = recurring_pages()
        duplicate = copy.deepcopy(pages[1597399][0])
        pages[1597399][0].update(runId=None, id=None)
        pages[1597399].append(duplicate)
        baseline, candidate, _, reads, *_ = compare(pages, membership(load_collector(), pages))
        self.assert_same_answer(baseline, candidate)
        self.assertIn(1569345, reads)
        self.assertEqual(
            [occ["build"] for occ in candidate["source_a"]["Sample.RecurringTests.First"]["occ"]],
            [1576238, 1569345],
        )

    def test_partial_nonrepresentative_counterexample_is_three_to_two(self):
        pages = recurring_pages()
        history = membership(load_collector(), pages)
        history[1569345].remove("Sample.RecurringTests.Second")
        baseline, candidate, _, reads, error, _ = compare(pages, history)
        self.assertNotIn(1569345, reads)
        name = "Sample.RecurringTests.Second"
        self.assertEqual(baseline["source_a"][name]["count"], 3)
        self.assertEqual(candidate["source_a"][name]["count"], 2)
        self.assertEqual(candidate["source_a"][name]["builds"], SOURCES["source_a"][:2])
        self.assertEqual(baseline["source_a"][name]["occ"], candidate["source_a"][name]["occ"])
        self.assertEqual(error, "")

    def test_unknown_coverage_restores_partial_counterexample(self):
        pages = recurring_pages()
        history = membership(load_collector(), pages)
        history[1569345] = None
        baseline, candidate, original_reads, reads, *_ = compare(pages, history)
        self.assert_same_answer(baseline, candidate)
        self.assertEqual(reads, original_reads)

    def test_zero_observations_are_unknown_even_when_source_has_failures(self):
        pages = sample_pages()
        history = membership(load_collector(), pages)
        history[1576238] = set()
        baseline, candidate, original_reads, reads, *_ = compare(pages, history)
        self.assert_same_answer(baseline, candidate)
        self.assertEqual(reads, original_reads)

    def test_provider_retrieval_error_is_logged_and_unknown(self):
        pages = sample_pages()
        collector = load_collector()
        calls = []
        collector["failed_results"] = lambda bid: calls.append(bid) or iter(pages[bid])

        def unavailable(bid):
            raise collector["TestHistoryUnavailable"]("synthetic retrieval error")

        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            candidate = collector["aggregate"](SOURCES["source_a"], history_provider=unavailable)
        baseline = collector["aggregate_results"](SOURCES["source_a"])
        self.assertEqual(candidate, baseline)
        self.assertEqual(calls[:3], SOURCES["source_a"])
        self.assertEqual(error.getvalue().count("UNKNOWN"), 3)

    def test_invalid_history_is_logged_and_unknown(self):
        pages = sample_pages()
        for invalid in (["Sample.Tests.Test"], {""}, {"not.normalized(value: 1)"}, {1}):
            with self.subTest(invalid=invalid):
                history = membership(load_collector(), pages)
                history[1576238] = invalid
                baseline, candidate, original_reads, reads, error, _ = compare(pages, history)
                self.assert_same_answer(baseline, candidate)
                self.assertEqual(reads, original_reads)
                self.assertIn("invalid method set", error)


if __name__ == "__main__":
    unittest.main()
