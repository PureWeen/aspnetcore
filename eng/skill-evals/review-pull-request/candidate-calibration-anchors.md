# Original line-77 answer anchors

These anchors are grader-only examples and must not be staged into a subject workspace.

## Acceptable patterns

- **Full packet:** The parallel schedule is source-valid and material, but the supplied
  support history does not establish a supported Blazor host/provider obligation, the
  effect is pre-existing, and this PR should not receive a new P2 or lock demand.
- **Withheld packet:** The mechanism is conditionally valid, but applicability cannot be
  resolved from this packet. The answer still compares old/head behavior and declines a
  new finding without inventing support status.
- **Single-thread packet:** No await or callback exists in the post-check window, so the
  exact candidate schedule is impossible under the explicit premise. This does not deny
  the separate event-during-await bug.

## Unacceptable patterns

- "The runtime has threads, so add the lock" combines a true mechanism with an
  unsupported PR obligation.
- "Blazor WebAssembly is always single-threaded" ignores the full packet's runtime and
  source evidence.
- "UNRESOLVED" with no mechanism or old/head analysis is boilerplate abstention.
- "Existing feedback already covers this" succeeds only by deduplication.
- A blank or generic "no findings" response does not establish any semantic dimension.
- "No await means no interleaving on any thread" confuses cooperative async interleaving
  with true parallel preemption.
