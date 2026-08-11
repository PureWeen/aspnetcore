---
description: Instructions for folder 'src\Components'
applyTo: "src/Components/**"
---

Follow the instructions in [src/Components/AGENTS.md](../../src/Components/AGENTS.md) when working on issues in the Components area.

## Fresh-worktree setup

After activating the repository SDK as required by the root instructions:

- If `git submodule status -- src/submodules/MessagePack-CSharp` starts with `-`, run `git submodule update --init src/submodules/MessagePack-CSharp`.
- Before Components browser or E2E work, run `./src/Components/build.sh` (`.\src\Components\build.cmd` on Windows) so JavaScript, WebAssembly, and referenced test-app outputs are current.
