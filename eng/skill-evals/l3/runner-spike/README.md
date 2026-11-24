# Vally review runner spike

This is a runner check only. It does not measure review quality or prove parity with hosted review. The only cases are PR 60724 and PR 69871.

## Set up Ubuntu

Use Ubuntu in WSL as an **unprivileged user**. Keep the clone, bundles, workspaces, and results in the Linux filesystem, not `/mnt/c`. Do not use Docker. Install Git, Node 22 or later, and the Linux prerequisites for the repository's .NET SDK.

From the handoff checkout, copy the spike specs and scripts to a scratch directory:

```bash
scratch="$HOME/runner-spike"
mkdir -p "$scratch/spec"
cp eng/skill-evals/l3/runner-spike/* "$scratch/spec/"
git clone --single-branch --branch main https://github.com/dotnet/aspnetcore.git "$scratch/aspnetcore"
cd "$scratch/aspnetcore"
git fetch --no-tags origin 144d56efebd32408e60cb9ec16ed521a9db36d31 405bb089835ba4f908e0b5038c42fca2c4bb84de
git switch --detach cbf730f5cd0bf8c04bf94e4f3869d6898065f37a
./eng/common/dotnet.sh
source ./activate.sh
dotnet --version
tools="$PWD/eng/skill-evals/evaluation-tools"
npm ci --prefix "$tools"
export PATH="$tools/node_modules/.bin:$PATH"
export COPILOT_CLI_PATH="$tools/node_modules/@github/copilot-linux-x64/copilot"
vally --version
"$COPILOT_CLI_PATH" --version
```

The clone must not be shallow. The lockfile pins Vally `0.19.0` and Copilot CLI `1.0.80`. On a different Linux architecture, select the matching installed CLI binary. Use an authenticated Copilot account for live trials; do not save authentication material in the scratch files. Set `REVIEW_MODEL` locally to the explicit model selected for the run.

## Run the spike

`produce.sh` verifies the two merge bases against Git history, packs the pinned trees into an isolated Git object store, and runs the real `prepare-review.cs --code-only` producer for both cases. The script activates the pinned SDK before invoking the producer. The archived base tips are comparison inputs, not verified historical review-time base SHAs. Both cases use the same fixed guidance commit.

```bash
cd "$scratch/spec"
bash produce.sh "$scratch"
vally experiment run preflight.experiment.yaml --variant probe \
  --param "REVIEW_MODEL=$REVIEW_MODEL" --workspace "$scratch/workspaces/preflight" \
  --output-dir "$scratch/results/preflight" --workers 1
node verify-staging.mjs "$scratch"
```

**Known gaps:** Hosted review runs with `bash` disabled. The historical spike specs did not deny shell or write tools, and single-reviewer trials used `bash`. Before the next live run, configure the runtime to deny shell and write tools; prompt instructions and a post-run grader do not deny execution. Reviewers must also run as an unprivileged user because `chmod 000` does not stop root.

After applying those restrictions, run one trial per case per variant. Start with `pipeline` and check its saved native events before running `single`. Stop on a CLI version mismatch, failed worker/verifier count, or any masked guide read. Keep all generated data outside the repository.

```bash
variant=pipeline
vally experiment run review.experiment.yaml --variant "$variant" \
  --param "REVIEW_MODEL=$REVIEW_MODEL" --workspace "$scratch/workspaces/review" \
  --output-dir "$scratch/results/review" --workers 1
```

Repeat with `variant=single` only after the pipeline check passes. Use each saved trial's native `events.jsonl` with `node trial-receipts.mjs <native-event-file>`. For each single-reviewer trial also run `node saved-review-check.mjs mask <native-event-file>`. Use `node saved-review-check.mjs self-test` for the offline failure-classifier checks.

## Pass checks

1. **Pipeline:** Native worker starts equal the manifest's routed-guide count; a findings result requires one verifier start. The native session-start record must report CLI `1.0.80`.
2. **Entry:** The staged `entry.md` files match their respective source prompts, while saved stimulus prompts are identical across variants.
3. **Mask:** The files listed in `masked-guide-paths.txt` have mode `000`; no guide reads appear in the single-reviewer traces.
4. **Trace:** Final findings and read receipts can be extracted, and a reviewer-declared failure can be distinguished from an infrastructure error.
5. **Staging:** The complete producer bundles stage intact under Vally. Read and hash the longest staged file and record its path length.
6. **Reuse:** Run `node saved-review-check.mjs findings <single-results> <pipeline-results>` and `node saved-review-check.mjs timing <single-results> <pipeline-results>` on the same saved `results.jsonl` files. The two comparisons must report matching input digests without rerunning reviewers.
