# C3 independent review — 2026-11-11

Reviewed `e9aee56d5f0999bde775512dc40ccd52a2b10be6..e35a665`, the
author's `.ai-report.md`, the C3 design and inherited `origin/agent/c3` work.
An independent agent reviewed native removal handling and key lifecycle;
the coordinator reviewed app, UI, storage and counters. The independent
agent also reviewed the resulting native/storage fix.

## Fixed

- Own accepted MLS removals now use `c7MergePendingCommit` and record its
  authenticated removal epoch atomically with sealed state and outbox
  settlement. Both normal completion and lost-response own echoes are covered.
  This includes device-revocation coordinators, which do not pass through the
  account-removal UI's explicit rotation mark. Unused exporter roots are wiped.
- Key-request replies stop announcing after a removal starts, including after
  the key-send await. A cancelled reply does not consume the hourly allowance.

The two new native tests failed before the fix: normal completion left the
watermark null; the own echo never reached the removal-aware cancellation
fence. Both pass afterward with the configured native library. Adds,
self-updates, staged-only removals, cancelled echoes, retry and duplicate
completion are covered. A real encrypted-store trigger aborts the watermark
insert after state/outbox mutation: the entire transaction rolls back, then
retry commits all three together without advancing the sync cursor.

The new reply regression failed before the fix (expected zero completed
answers, received one). It now checks no post-removal announcement and an
immediate retry after rotation.

The first full-suite run caught native test adapters which forwarded only the
old merge method. They now forward the outcome method to the real device,
preserving their existing fault injection. Their 21 tests pass.

## Delayed first-delivery reproduction (still fails)

A temporary test using the existing real-codec service harness reproduced the
freshness flaw; it was removed from the passing suite, not marked skipped.
The receiver never observed K1, receives K2 after rotation, then receives K1
for the first time from an authenticated admin. `currentKey` selects K1.
This harness demonstrates the selection bug, not a complete malicious-relay
native run. Existing MLS past-epoch retention also makes delayed messages a
relevant case; key events currently discard their epoch.

Reproduce inside `c3_community_info_service_test.dart` with its helpers:

```dart
final admin = device('admin', {_shared}, admin: true);
await admin.service.publish(community, (r) => named('Club', r), mint: true);
final home = admin.service.homeOf(community)!;
final retired = (await admin.service.currentKey(home, _community))!;
final member = device('member', {_shared});
await admin.service.markRotationDue(home, _community);
expect(await admin.service.runRotations((_, __) => [community]), 1);
final fresh = (await member.service.currentKey(home, _community))!;
await net.deliver(admin, _shared, AppPayloadType.infoKey,
    infoKeyBody(subjectKind: infoKindCommunity, subjectId: _community,
        key: retired.key!));
expect((await member.service.currentKey(home, _community))!.keyId, fresh.keyId);
// Fails: actual is retired.keyId.
```

## Still blocking C3

- Production has no verified C4 role source; the debug hook cannot establish
  production acceptance. The signed channel-info restriction flag is missing.
- Community/channel creation still sends plaintext names. The refusal,
  column removal and legacy-name fallback removal are absent.
- Channel conversion and category/icon management UI are absent. There is no
  complete app-to-app C3 acceptance run with production role wiring.
- Key freshness still depends on first local arrival (`currentKey`). A retired
  key first delivered after its replacement can become current. Tombstones
  prevent replay of already-observed identities, not this case; events retain
  no authenticated MLS epoch. Fixing this requires a reviewed freshness rule,
  rather than weakening retention or guessing from server order.
- Distinct retired keys leave unbounded identity tombstones. Authenticated
  member traffic can grow local storage and the scans used for refresh.
  Simply pruning tombstones would reintroduce the known replay bug.

## Boundaries and counters

Local schema remains 32, latest server migration remains 0066. Reserved schema
35 and migration 0067 are unused; this review uses existing encrypted metadata
and existing ABI 13 outcomes. No dependency, ABI or counter changes. Release
entry point still installs `UnavailableCryptoService`; no release gate changed.

## Checks

- Focused Go storage/domain/app tests and `go vet ./...`: pass.
- `cargo test`: 230 passed, eight existing ignores; clippy with warnings denied:
  pass.
- Focused Flutter C3/native/encrypted-store suite: 178 passed, no skips.
- Full `scripts/lint.ps1`: pass, including Flutter analyze and format.
- Native fault/record-limit adapters: 21 passed after updating forwarding.
- Full `scripts/test.ps1`: pass (exit 0), including Python fixtures, all Go
  packages, Rust and 2,468 Flutter tests with 21 existing skips.
- `git diff --check`: pass.

Verdict remains FAIL because passing isolated checks does not complete C3.
