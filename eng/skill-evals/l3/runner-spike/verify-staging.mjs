import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";

function inventory(root) {
    return new Set(readdirSync(root, { recursive: true, withFileTypes: true })
        .filter(entry => entry.isFile())
        .map(entry => join(entry.parentPath, entry.name).slice(root.length + 1)));
}

assert.ok(process.argv[2], "Usage: verify-staging.mjs <scratch root>");
const root = resolve(process.argv[2]);
for (const id of ["pr60724", "pr69871"]) {
    const producer = join(root, "spec", "bundles", id);
    const staged = join(root, "workspaces", "preflight", "probe", id, "bundle");
    const actual = inventory(staged);
    assert.deepEqual(actual, inventory(producer));
    assert.equal(JSON.parse(readFileSync(join(staged, "manifest.json"))).ready, true);
    let longest = "";
    let longestHash;
    for (const relative of actual) {
        const path = join(staged, relative);
        const bytes = readFileSync(path);
        assert.ok(bytes.equals(readFileSync(join(producer, relative))), `Changed bytes: ${relative}`);
        if (path.length > longest.length) {
            longest = path;
            longestHash = createHash("sha256").update(bytes).digest("hex");
        }
    }
    console.log(JSON.stringify({ id, files: actual.size, longest, length: longest.length, longestHash }));
}
