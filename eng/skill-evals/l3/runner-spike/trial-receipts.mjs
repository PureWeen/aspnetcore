import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

const trace = process.argv[2];
assert.ok(trace, "Usage: trial-receipts.mjs <native event file>");
const events = readFileSync(trace, "utf8").trim().split("\n").map(line => JSON.parse(line));
const start = events.find(event => event.type === "session.start")?.data;
assert.equal(start?.copilotVersion, "1.0.80");
const { cwd } = start.context;
const manifest = JSON.parse(readFileSync(join(cwd, "bundle/manifest.json")));
const starts = events.filter(event => event.type === "tool.execution_start");
const ends = new Map(events.filter(event => event.type === "tool.execution_complete")
    .map(event => [event.data.toolCallId, event.data]));
const tasks = starts.filter(event => !event.agentId && event.data.toolName === "task")
    .map(event => ({
        agent: event.data.arguments?.agent_type,
        started: events.some(child =>
            child.type === "subagent.started" && child.data.toolCallId === event.data.toolCallId),
    }));
const reads = starts.filter(event => /^(view|read_file|grep|rg|glob|search)$/.test(event.data.toolName))
    .map(event => ({
        tool: event.data.toolName,
        args: event.data.arguments,
        success: ends.get(event.data.toolCallId)?.success ?? null,
    }));
const final = events.filter(event => event.type === "assistant.message" && !event.agentId &&
    /^STATUS: (FINDINGS|NO_FINDINGS|INCOMPLETE|BLOCKED)\b/.test(event.data?.content)).at(-1)?.data.content;
const variant = basename(dirname(cwd));
const status = final?.match(/^STATUS: (\w+)\b/)?.[1] ?? null;
if (variant === "pipeline") {
    assert.ok(status === "FINDINGS" || status === "NO_FINDINGS", `Review did not finish: ${status}`);
    assert.ok(tasks.every(task => task.started));
    const workers = tasks.filter(task => task.agent === "review-guide-worker");
    const verifiers = tasks.filter(task => task.agent === "review-candidate-verifier");
    assert.equal(workers.length, manifest.guides.length);
    assert.equal(tasks.length, workers.length + verifiers.length);
    assert.ok(verifiers.length <= 1);
    if (status === "FINDINGS") assert.equal(verifiers.length, 1);
}
console.log(JSON.stringify({
    variant, case: basename(cwd), version: start.copilotVersion,
    expectedWorkers: manifest.guides.length, status, tasks, reads, final,
}, null, 2));
