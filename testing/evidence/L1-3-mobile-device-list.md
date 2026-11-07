# L1-3 mobile: approved-device list (D94, D100)

Run on 2026-11-07 on Linux, Flutter 3.44.0, native library built from this
tree (`cargo build --release`, ABI 14), with
`VERITRA_CRYPTO_LIBRARY` set and `VERITRA_REQUIRE_NATIVE_CRYPTO=1`.

New tests (all pass):

- `mobile/test/l1_device_list_pins_test.dart` (15): the pins against the
  shared vector `testing/vectors/l1-device-list-v1.json` and real signatures.
  First sight pins the whole chain; later versions step forward; a lower
  head, a damaged step and a damaged first chain change nothing; another
  account's chain is refused; a validly signed other branch at the pinned
  version is a sticky conflict; refreshes are rate-limited; verdicts
  (approved, removed, unapproved for an unknown key or an unspellable id,
  checking for no list or no server); the add gate returns only the pinned
  key; own genesis and add pin forward.
- `mobile/test/l1_device_list_store_test.dart` (8): schema 26 on drift and in
  memory: pins only forward from the expected version, sticky conflict, leaf
  rows replace a group and mark the hold, a schema 20 file upgrades to 26,
  sign-out clears every L1 table.
- `mobile/test/l1_native_gate_test.dart` (8), real OpenMLS devices: an
  approved device is added and messages flow; an unlisted device is never
  staged; a key package with another key than the pinned one is refused; no
  pins means no add; a commit that adds an unapproved device is applied, holds
  sends and self-updates, hides that device's message (placeholder
  `unapproved:<event>:<id>`, no text) while the real device still speaks, and
  its removal releases the hold; a Welcome into a group with an unapproved
  leaf joins and holds until the list approves it; an unreachable list is
  "checking" (held, message hidden) and then released; a group with no rows is
  judged before use.
- `mobile/test/l1_app_state_lists_test.dart` (2), AppState with the native
  engine and real pins against a fake server that keeps the chain like L1-2:
  setup carries a genesis naming this device and key; a pre-L1 account
  reviews its devices once (change 6), the unticked device is revoked, a
  removal refused with 409 is re-signed and accepted, and the recovery key
  sets change 5. Every statement verifies as the chain's next step.

Existing native tests now run with the add gate and leaf judge on: devices
they enroll are approved through `mobile/test/l1_test_lists.dart`
(`TestNativeCryptoService`), never by switching the gate off. 15 such files
were moved to it; the two test device wrappers forward the two new device
calls.

Full suite: see the PR's check run (`.claude/hooks/check.sh`).

Not covered here: the K0-R change-4 post and the K2 change-2 approval run
only in the full flows (`k0_recovery_native_flow_test.dart`,
`device_link_v3_flow_test.dart` use the shared test list, which serves no
chain, so those versions are not posted there). The demo e2e with a real
server is L1-5.
