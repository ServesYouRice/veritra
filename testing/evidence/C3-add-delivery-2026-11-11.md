# C3: add-key delivery and overlapping removals

C3 remains partial. This completes the foreground add-key delivery slice;
it does not complete production role wiring or encrypted creation.

## Changes

- The device merging its accepted add bundle delivers the current info key
  in the owning MLS group. Foreground sync resolving an own commit after a
  lost response also delivers it. Sends run outside the session queue.
- Accepted records under that same key are announced again only where the
  verified role policy allows the sending account to author them. No new
  key is minted for delivery. Private keys never go to the shared group.
- Request/answer remains recovery for interruption, missing topology/keys,
  unavailable verified roles and inbound-only background wakes. Proactive
  delivery is best effort; it has no second durable delivery ledger.
- Completed and tested the inherited uncommitted rotation-token fix: a newer
  removal cancels a superseded pass before further re-sealing, retains its
  mark and gets a fresh key without inheriting the abandoned pass's backoff.

## Verification

- `cargo build --release`: passed. Every native Flutter check used
  `VERITRA_CRYPTO_LIBRARY` pointing to this worktree's absolute release DLL.
- Focused service/native Flutter tests: 52 passed, no skips. Includes real
  OpenMLS add/Welcome/merge/send/decrypt through AppState, both ordinary and
  lost-response delivery, without a joiner key request. Verified role state
  is explicitly test-injected; this is not evidence of production C4 wiring.
- Regressions also cover overlapping removals after key exposure, immediate
  retry, group isolation, missing keys, pending removals, failed sends,
  restricted authorship and excluding records encrypted under another key.
- `flutter analyze --no-pub`: passed.
- `scripts/lint.ps1`: passed, including Go vet, Rust fmt/clippy, Flutter
  analyze and Dart formatting.
- `scripts/test.ps1`: exit 0. Release-policy fixtures, all Go tests, 230
  Rust tests (8 existing ignores), and 2,456 Flutter tests (21 existing skips)
  passed. `git diff --check` passed.
  Raw local logs: `c3-add-focused.log`, `c3-add-full-test.log`,
  `c3-add-full-lint.log`.
- Initial native fixture omitted required names, then its C0 layout
  generation; corrected the fixture and verified both real delivery paths.

## Decisions and remaining work

`origin/agent/c3` is already an ancestor; its sender follow-up was already
ported. Inspected its history and current implementation rather than copying
unrelated changes. Used the design's committing-device delivery and owning
group rules. Worked alone per the task; no review agent or advisor was used.

No STATE.md, release gate, ABI, dependency, schema or migration changes.
Reserved local schema 35 and migration 0067 remain unused. No push or PR.

Still needed: production verified C4 role source and restriction flag;
remote/moderator-removal rotation; channel conversion and category/icon UI;
encrypted creation, plaintext-name refusal and column removal. The earlier
key-retention residuals (unbounded identity tombstones, history already pruned
by older builds) remain. A production-wired C3 flow and independent review
are still required before declaring the whole package complete.
