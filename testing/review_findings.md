# Testing-gap review outcome

The source review was performed against commit
`3ee785db9083eb67f3b16c3f83050ac3b365eb19` on 2026-08-23. The routing below
was rechecked against the subsequent same-day tree before the contracts were
added; every executor must still reconfirm its gap on current `HEAD`.

## Verdict

The original testing audit is useful as brainstorming, but not reliable enough
to execute. It was not revision-bound, contains stale/false inventory, names
tests and commands that do not exist, conflicts with current board status, and
mixes release blockers with dependency-blocked or later measurement work.

The confirmed work is now split into bounded, dependency-aware
[QA contracts](../implementation/tasks/test-followups/README.md). Lower-tier
executors should receive one contract, not the original reports.

## Main audit defects

- Versions, migration counts, test counts, and referenced source paths were
  already stale when checked.
- The traceability matrix names nonexistent Dart tests, the wrong Go packages,
  a nonexistent metrics file, and a placeholder Docker command.
- It asks for unsupported migration downgrades, unapproved dependencies, a
  removed background Dart isolate, and positive crypto UI that the release gate
  intentionally forbids.
- It labels nearly everything critical without reconciling D02/D03,
  dependencies, external G24/G25 evidence, or post-correctness measurement.

Examples of false or overstated claims include missing MLS transaction tests,
FFI panic barriers, slow-client WebSocket tests, proxy/rate-limit tests, upload
failure tests, outbox restart tests, wrong-key tests, and accessibility tests;
all already exist in the reviewed tree. Historical migration upgrades,
real-device evidence, and focused pipeline/provider tests remain valid gaps.

## Confirmed gap routing

| Finding | Disposition |
|---|---|
| Mobile omits the server-required call `version`, invitee, and `expected_version` transition field. | [QA03](../implementation/tasks/test-followups/QA03-call-contract.md) |
| The Dart attachment file/framing/cleanup pipeline has no direct test. | [QA04](../implementation/tasks/test-followups/QA04-attachment-crypto-pipeline.md) |
| The Dart backup upload/recovery pipeline has no direct test. | [QA05](../implementation/tasks/test-followups/QA05-backup-crypto-pipeline.md), blocked with I45 |
| FCM/APNs/WebPush requests and error classes lack focused tests. | [QA06](../implementation/tasks/test-followups/QA06-push-provider-contracts.md), blocked with I41 |
| App-level durable push delivery outcomes lack focused tests. | [QA07](../implementation/tasks/test-followups/QA07-push-worker-outcomes.md), blocked with I41 |
| The active Flutter MethodChannel/EventChannel push bridge lacks direct tests. | [QA08](../implementation/tasks/test-followups/QA08-mobile-push-bridge.md), blocked with I41 |
| Existing adversarial release/retraction tests are not run; two evidence scripts lack fixtures. | [QA01](../implementation/tasks/test-followups/QA01-release-policy-fixtures.md) |
| Historical forward-upgrade and failed-migration atomicity fixtures are absent. | [QA09](../implementation/tasks/test-followups/QA09-migration-upgrade-fixtures.md), blocked with I45 |
| Go/Flutter coverage is uploaded without a regression floor; Rust has no artifact. | [QA10](../implementation/tasks/test-followups/QA10-coverage-baseline.md) |
| Debug simulator success is indistinguishable from signed iOS release evidence. | [QA02](../implementation/tasks/test-followups/QA02-ios-evidence-semantics.md) |

## Existing canonical work, not duplicated

- Goldens and automated accessibility: T43C; signed TalkBack/VoiceOver: G24.
- Live multi-device MLS/device-link, signed builds, TURN, and network changes:
  G24/G25.
- WebSocket parser fuzz/protocol evidence: T48B.
- Transport/log privacy: T48A.
- Chaos, soak, capacity, and benchmarks: T47/T49 after correctness blockers.

This was a static review. At review time Go, Cargo, Flutter, and usable Python
were unavailable; Docker was installed but its engine was not running. No
runtime check was represented as passing.
