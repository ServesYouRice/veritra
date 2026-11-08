# L1-2 server: approved-device list (D94)

Run on 2026-11-07 on Linux with Go 1.26.10, from the `agent/l1-server` worktree
(branch from `origin/main` at `246c9bd`).

- `gofmt -l .` and `go vet ./...` in `server/`: clean.
- `go test ./...` in `server/`: every package passed, including the new
  `internal/devicelist` unit tests, `internal/storage` gate tests and the
  `internal/httpapi` route tests (migration 0051 is applied by the test
  harness like every other migration).
- Not run: Rust, Flutter and the mobile tests (no change outside `server/`
  and `docs/`).

What the tests cover:

- `devicelist`: byte layout, `list_hash` and signed-message construction
  written out independently of the code; strict parse (trailing bytes, order,
  repeats, counts, ids, flags, signer shapes, 4 KiB); every change kind; every
  rule violation; no return of a removed id or key; the signature is outside
  the hash and covers body, signer kind and signer id.
- HTTP: genesis at setup and register (stored, served, event, derived rows);
  a refused genesis leaves nothing behind and the reservation stays usable;
  readers (self, conversation peer, symmetric) and a byte-identical 404 for a
  stranger and an unknown account; batch `found: false` the same for both;
  paging (64 per account) and the batch budget (256); link approval v2 and v3
  (required with a head, stored in the device's transaction, wrong key, wrong
  signer, wrong kind, stale `prev_hash` and gap give 409 with the head
  version, replay adds nothing); revoke with and without a version; repair
  (no recent auth, only for already revoked devices); migration genesis
  (recent auth, live matching devices only, not twice); recovery key `PUT`
  (required with a head, must set a key, small-order key refused) and change 4
  (only from the device recovery enrolled, signed by the head's recovery key,
  one pair, not replayable); recovery claim on a head with no recovery key
  (same 401, same work, correct key not counted for D79, wrong key counted, no
  leak warning); account deletion removes the list; the audit trail carries
  only version and change.
- Storage: pending changes, key-package claims, commit bundles and
  conversation claims name only devices on an account's head, and are
  unchanged for an account with no list.

- Vector: `internal/devicelist/vector_test.go` runs the production parse and
  check over L1-1's `testing/vectors/l1-device-list-v1.json` (read from
  `agent/l1-core` at `4c2b5ff`, placed in the tree for the run and removed
  again): both chains accepted step by step with the vector's body, hash and
  signed message; every one of its 60+ refusals refused in its class
  (malformed, chain, rule, signature); the Ed25519 edge cases (the server is
  never stricter than a client). L1-1's own `vdl1_vector_test.go` also
  compiled and passed beside this code. The test skips while the file is not in
  the tree, so it only runs for real once L1-1 is merged.
- Alignment found by that run and fixed: ids up to 128 bytes (not 64), listed
  and recovery keys must be canonical non-small-order points, version 1 is a
  genesis and only version 1, a change 5 must change the recovery key. A
  recovery completion onto a list with no recovery key is refused.

Open: the key-package leaf-signature-key gate (bug-hunt Q-1) is not enforced.
Independent review of this step (design: Opus review) is still owed.
