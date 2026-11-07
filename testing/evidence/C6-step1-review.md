# C6 step 1 independent review (opus, 2026-11-06) — verdict: no blockers, ~85% confidence
Checks: cargo test --locked passed (123 lib tests incl. 9 report::tests); go test ./internal/franking 6/6 incl. TestSharedReportSealVector. Dart not run locally (CI mobile job runs with VERITRA_REQUIRE_NATIVE_CRYPTO=1, green on f23e4566).
Findings (all low/nit):
1. server/internal/franking/franking.go:36-54 Commit has no bounds; Rust requires ids 1..128 bytes, payload 1..64KiB (report.rs:196-204). Apply same bounds, return error.
2. report.rs:139-142 maps every hpke_seal error to InvalidInput; check low-order key explicitly before sealing and map other errors to Crypto (or document).
3. report_tests.rs:180-187 low-order test covers u=0,u=1 only; add the two order-8 u-coordinates and non-canonical p-1, p, p+1.
4. testing/vectors/c6-franking-v1.json thin: add commitment case with channel_id, hidden, multi-byte UTF-8/escaped text; add Go-sealed case opened by Rust (and Dart); move malformed frank cases from mobile/test/c6_report_crypto_test.dart:98-129 into shared vector.
5. docs/designs/C6-reports-franking.md:64 says sealed to owner's account key; code uses a separate seed-derived report key. Fix text; add open question on moderator inbox key distribution/rotation under C4 (removed moderator keeps the seed).
6. mobile/lib franking.dart:38-44 frankWireJson accepts "{}" producing invalid JSON; refuse it (unreachable today).
7. veritra_crypto.h:143-169 ABI 12 functions: state that out is left untouched on failure.
Conditions for step 2/3 wiring review:
G1 attribution relies on honest server row; state in design; UI must label server-only checks; moderators verify against own MLS copy.
G2 commitment context from authenticated sources only.
G3 frank_commit write-once in own column, not crypto_metadata.
G4 report aad binds recipient inbox, conversation_id, envelope_id, reporter.
G5 decide refusal of unfranked payloads once franking is on; plan rollout.
G6 reject duplicate JSON keys if a non-Dart verifier will exist.
