# C3 key freshness — 2026-11-11

Finding (review 2, high): `CommunityInfoService.currentKey` chose the key
whose id first arrived here last. A retired key first delivered after its
replacement became current, so later edits were sealed under a key the
removed member holds.

Fix: keys are ordered by the authenticated MLS epoch of the message that
carried them, and a key from before the group's last removal is never current.
Rule and residuals: `docs/crypto.md`, change log "C3 key freshness". Local
schema 35 adds the nullable `local_info_events.epoch` column.

## Tests

Written first, against the real-codec service harness
(`mobile/test/c3_community_info_service_test.dart`):

- `a retired key first delivered after its replacement never wins` — the
  review's reproduction, with the delayed copy keeping its epoch. Before the
  fix: expected the replacement key id, actual the retired one.
- `a key from before the last removal is never current, even alone` — before
  the fix: the retired key was returned.
- `an untrusted copy at an old epoch cannot retire the current key` — guard.

Before-fix output: [`c3-freshness-before-fix.log`](c3-freshness-before-fix.log).
After-fix output: [`c3-freshness-after-fix.log`](c3-freshness-after-fix.log).

Storage (`c3_community_info_payload_test.dart`, memory and SQLite stores): a
repeated key keeps its first arrival and lowest epoch; a tombstone keeps its
epoch; a schema-34 file upgrades with old rows' epoch unknown.

Native (`c3_native_info_send_test.dart`, real OpenMLS): the receiver stores the
sender's group epoch from the message header and ignores a forged
`mls_epoch` in the envelope metadata; the sender's own copy carries the same
epoch.

Existing rotation tests now move the harness group epoch with each simulated
removal, as a merged removal commit does.
