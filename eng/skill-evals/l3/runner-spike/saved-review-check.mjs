import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const [action, left, right] = process.argv.slice(2);
const jsonLines = path => readFileSync(path, "utf8").trim().split("\n").map(line => JSON.parse(line));
const digest = path => createHash("sha256").update(readFileSync(path)).digest("hex");
const heading = name => new RegExp(`^(?:#{1,6}\\s*)?(?:\\*\\*)?${name}(?:\\*\\*)?\\s*:?(?:\\*\\*)?`, "m");

function classify(row) {
    const text = row.trajectory?.output?.trim() ?? "";
    const status = text.match(/^STATUS: (FINDINGS|NO_FINDINGS|INCOMPLETE|BLOCKED)\b/)?.[1];
    if (status === "FINDINGS" || status === "NO_FINDINGS") {
        const start = heading("NEW_FINDINGS").exec(text);
        assert.ok(start, `Missing NEW_FINDINGS: ${row.stimulus}`);
        const remainder = text.slice(start.index + start[0].length);
        const end = heading("(?:UNRESOLVED|EXISTING_FEEDBACK_COVERAGE|DISCARDED)").exec(remainder);
        assert.ok(end, `Missing section after NEW_FINDINGS: ${row.stimulus}`);
        const findings = remainder.slice(0, end.index).trim();
        const count = findings.match(/^(?:\d+[.)]\s+|[-*]\s+\*\*)\S/gm)?.length ?? 0;
        if (status === "FINDINGS") {
            assert.ok(count >= 1 && count <= 5, `FINDINGS must contain one to five entries: ${row.stimulus}`);
        } else {
            assert.equal(count, 0, `Unexpected findings: ${row.stimulus}`);
            assert.match(findings, /^(?:[-*]\s*)?(?:none(?:\.[^\n]*)?|\(none\)|\[\])?$/i);
        }
        return { kind: "completed-review", status, count };
    }
    if (row.status === "error" && row.error) return { kind: "infrastructure-error" };
    if (status) return { kind: "reviewer-failure", status };
    return { kind: "unknown", runnerStatus: row.status };
}

if (action === "self-test") {
    const row = { stimulus: "fixture", status: "error", error: { code: "fixture-launch-error" } };
    assert.equal(classify(row).kind, "infrastructure-error");
    const trajectory = { output: "STATUS: BLOCKED\nMissing required review input." };
    assert.equal(classify({ ...row, status: "success", trajectory }).kind, "reviewer-failure");
    trajectory.output = "STATUS: FINDINGS\n\n## NEW_FINDINGS\n1. Finding\n\n## DISCARDED\nNone.";
    assert.equal(classify({ ...row, trajectory }).kind, "completed-review");
    trajectory.output = trajectory.output.replace("1. Finding", "None.");
    assert.throws(() => classify({ ...row, trajectory }), /one to five/);
} else if (action === "mask") {
    const events = jsonLines(left);
    const cwd = events.find(event => event.type === "session.start").data.context.cwd;
    const paths = readFileSync(join(cwd, "masked-guide-paths.txt"), "utf8").trim().split("\n");
    assert.ok(paths.length > 0 && paths.every(path => (statSync(join(cwd, path)).mode & 0o777) === 0));
    const names = new Set(paths.map(path => path.split("/").at(-1)));
    const completed = new Map(events.filter(event => event.type === "tool.execution_complete")
        .map(event => [event.data.toolCallId, event.data]));
    const hits = events.filter(event => event.type === "tool.execution_start" &&
        /^(view|read_file|grep|rg|glob|search|bash|shell|powershell)$/.test(event.data.toolName))
        .flatMap(event => [...names].filter(name => {
            const args = JSON.stringify(event.data.arguments ?? {});
            const result = JSON.stringify(completed.get(event.data.toolCallId)?.result ?? {});
            return args.includes(name) ||
                (/^(grep|rg|search|bash|shell|powershell)$/.test(event.data.toolName) && result.includes(name));
        }));
    console.log(JSON.stringify({ paths, hits }));
    assert.equal(hits.length, 0);
} else if (action === "findings" || action === "timing") {
    const files = [left, right];
    const hashes = files.map(digest);
    const [baseline, pipeline] = files.map(path => new Map(jsonLines(path)
        .filter(row => row.type === "trial-result").map(row => [row.stimulus, row])));
    assert.equal(baseline.size, 2);
    assert.equal(pipeline.size, 2);
    const rows = [];
    for (const [stimulus, a] of baseline) {
        const b = pipeline.get(stimulus);
        assert.ok(b);
        assert.equal(a.trajectory.stimulus.prompt, b.trajectory.stimulus.prompt);
        const [singleResult, pipelineResult] = action === "findings"
            ? [a, b].map(classify)
            : [a, b].map(row => ({ elapsedMs: row.durationMs }));
        rows.push({ stimulus, baseline: singleResult, pipeline: pipelineResult });
    }
    assert.deepEqual(files.map(digest), hashes);
    console.log(JSON.stringify({ action, hashes, rows }, null, 2));
} else {
    throw new Error("Usage: saved-review-check.mjs self-test | mask <native event file> | findings|timing <single results> <pipeline results>");
}
