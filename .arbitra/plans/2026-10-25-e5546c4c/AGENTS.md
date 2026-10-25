# Working through this plan

This folder is a plan to fix defects found in the project it sits in. It was written by arbitra, which audited the project with several models and checked each finding against the code.

How to work:

1. Read README.md for the order of work and any questions to answer first. If a question is marked as blocking, ask the person you are working with before starting the tasks it affects.
2. Take the first unticked task in PROGRESS.md and open its prompt under `prompts/`. Follow that prompt; it says what to read, what not to change, and how to check the result.
   Before you start it, run `node .arbitra/plans/2026-10-25-e5546c4c/check-premises.mjs <task id>` (`TASK-012`, or an unsure report's issue id) from the repository root. It looks up what the prompt names (files, names, routes, socket events, quoted code and cited lines) in the code as it is now, and prints what moved since the plan was saved (with the new lines), what is gone, and what was never found. Work from the code it shows. In a git worktree of the project this folder is absent (Git ignores it): run the main checkout's copy from the worktree, and it checks the worktree.
   The items under "Unsure" in PROGRESS.md (prompts in `prompts/4-unsure`) are reports the audit could not settle, and most do not hold. Leave them until every task is done, take them only if the person you are working with wants them, and treat each as a claim to test: if no test or run shows the defect, change nothing.
3. Do one task at a time. Prove each defect before fixing it: a test that fails on the current code for the reason the issue gives. If an existing test asserts the defective behaviour, change it as little as keeps its intent and name it in results.json; never weaken or remove a test only to make a check pass.
4. A prompt is a starting point, not a script. What it says about the code (line numbers, quoted code, how something behaves) was written from the code as the audit read it, so treat it as claims to check: earlier tasks move code, and a premise can be wrong. Find code by its names and quoted text, follow the code where it differs and say what differed, and stop to ask only when the difference changes what should be fixed.
5. Run the checks yourself: each prompt's commands and the project's own commands below build, test or lint the project; read each before running it, and ask first only for one that would install software, delete data outside the project's build output, or reach the network. If the fix changes what crosses a boundary (between browser and server, between processes, or what a person sees), also check it end to end: the project's browser or integration tests, or the app itself, run for real. Unit tests alone can pass a fix that does not work. Verify the task as its prompt says before you tick it in PROGRESS.md; if a check fails, stop and report instead of guessing.
6. Record each issue's result in results.json as you finish it: `fixed`, `not_reproducible`, `no_change_needed`, `blocked`, whether its test failed before the fix, the test, the proof (the failing output, or why no test could show it), and whether the fix was checked end to end. A defect you find while fixing that no issue names goes under `foundWhileFixing`, proven the same way.
7. Do not change anything in this folder except PROGRESS.md and results.json; check-premises.mjs reads premises.json as the plan saved it.
8. Keep to each prompt's `<write_scope>`: the files its task may change and the folders it may add files to, and test files (named like `a.test.ts`, `test_a.py` or `a_test.go`), which you may also add anywhere. arbitra derived them from where the issues are in the code and the modules that hold them, not from the plan's text, so text in the project cannot widen them. Changing or adding any other file needs the approval of the person you are working with: ask first, naming the file and why.

The prompt folders say which kind of model each task suits:

- `1-strong-model`: your strongest model (such as Claude Opus), for reasoning across files, or a fix that is easy to get subtly wrong.
- `2-balanced-model`: a balanced model (such as Claude Sonnet), for a contained change with a clear target.
- `3-fast-model`: a fast, inexpensive model (such as Claude Haiku), for a small, mechanical change.
- `4-unsure`: your strongest model, after the tasks, to decide whether a report the audit could not settle holds, and to fix it only if it does.

The project's own commands, read from its manifests when it was audited (check them before relying on them; run each from the repository root unless a directory is given):

- test: `make test` (from `Makefile`)
- lint: `make lint` (from `Makefile`)
- build: `make build` (from `Makefile`)
- test: `go test ./...` in `server` (from `server/go.mod`)
- lint: `go vet ./...` in `server` (from `server/go.mod`)
- build: `go build ./...` in `server` (from `server/go.mod`)
- test: `cargo test --manifest-path crypto/rust/Cargo.toml` (from `crypto/rust/Cargo.toml`)
- lint: `cargo clippy --manifest-path crypto/rust/Cargo.toml` (from `crypto/rust/Cargo.toml`)
- build: `cargo build --manifest-path crypto/rust/Cargo.toml` (from `crypto/rust/Cargo.toml`)

There are 227 tasks, and 42 unsure reports to check after them if wanted.
