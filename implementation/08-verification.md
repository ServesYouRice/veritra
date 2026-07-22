# Plan 08 — Security, contract, and release verification

These cards verify boundaries that unit tests alone cannot prove. Keep test
fixtures synthetic and never log decrypted payloads when a client-side crypto
test necessarily creates them in memory.

## V01 — Add migration-backed storage invariant tests

Audit references: TEST-01, LOG-01.

Depends on: S01, S02.

Objective:
Catch schema/query drift through real migrated SQLite databases and meaningful
data paths.

Steps:

1. Inventory storage packages and map exported behaviors to migrations.
2. Prioritize key packages, membership, message mutations, attachments,
   backups, devices, and retention.
3. Exercise successful reads/writes plus authorization and constraint failure
   paths; do not merely call methods that can return before SQL executes.
4. Run each selected suite against a freshly migrated database.
5. Add a CI command that cannot silently skip the integration cases.

Acceptance:

- Misspelled/nonexistent tables and important constraint drift fail tests.
- Fixtures contain random ciphertext bytes, never realistic message text.

## V02 — Test the documented reverse-proxy topology

Audit references: TEST-03, SEC-03, SEC-04.

Depends on: Y05, S04, D01.

Objective:
Verify client identity, rate limits, setup authorization, WebSocket caps, and
forwarding behavior through the supported proxy configuration.

Steps:

1. Start the application behind the documented proxy in an isolated test
   network.
2. Cover trusted/untrusted forwarding headers, multiple clients, spoofing,
   loopback upstreams, WebSocket upgrades, and connection limits.
3. Verify forwarded scheme/host behavior used for security decisions.
4. Confirm bootstrap remains token-protected when the proxy connects locally.
5. Run the test in CI or a documented nightly environment.

Acceptance:

- Proxy clients are separated only when the trusted-proxy policy permits it.
- Forwarding-header spoofing and tokenless setup both fail closed.

## V03 — Harden or replace the WebSocket parser

Audit reference: TEST-02.

Depends on: Y05.

Objective:
Establish parser safety under malformed and adversarial frames.

Steps:

1. Decide whether to retain the custom parser or adopt a maintained library.
2. If adding a library, review license/security history and update
   THIRD_PARTY_NOTICES.md before implementation.
3. Add fuzz seeds for masking, lengths, fragmentation, continuation, control
   frames, UTF-8, close codes, and truncated input.
4. Assert frame/message limits, bounded allocation, cancellation, and clean
   connection teardown.
5. Preserve every crashing input as a regression seed.

Acceptance:

- The fuzz target runs in CI for a bounded time and longer on schedule.
- Malformed frames cannot panic, grow memory without bound, or bypass limits.

## V04 — Add live server-to-Dart API contract tests

Audit reference: TEST-04.

Depends on: B03.

Objective:
Detect route, method, status, pagination, and JSON model drift across the Go
server and Flutter client.

Steps:

1. Start a migrated server with deterministic synthetic accounts.
2. Drive representative Dart API calls for auth, conversations, messages,
   sync, attachments, communities, devices, and backups.
3. Cover error envelopes, nullable/optional fields, unknown fields, cursors,
   and version negotiation.
4. Keep message/attachment bodies opaque random bytes.
5. Make the contract suite a required change gate.

Acceptance:

- A route or response-model mismatch fails before release.
- Tests use the production serializer/client rather than duplicate fixtures.

## V05 — Exercise backup and restore end to end

Audit reference: TEST-05.

Depends on: D03.

Objective:
Prove an operator can restore consistent server state without touching the
live root.

Steps:

1. Create synthetic accounts, memberships, ciphertext messages, blobs, keys,
   and deletion state.
2. Back up while the server follows its documented consistency procedure.
3. Restore into a new root and start a separate instance.
4. Verify authorization, row/blob integrity, retained deletions, and instance
   identity expectations.
5. Inject truncated, corrupt, wrong-key, and interrupted backups.

Acceptance:

- A valid restore passes integrity and API checks.
- Invalid backups fail closed with privacy-safe errors.
- The test never overwrites or reads an operator's real data root.

## V06 — Run the two-device cryptographic matrix

Audit references: TEST-06, SEC-01, LOG-04, LOG-06.

Depends on: C12, M03, M07, M09.

Objective:
Validate real cross-device crypto behavior, not only server ciphertext
transport.

Steps:

1. Cover two users and two devices per user across create, add, send, receive,
   offline catch-up, edit/delete/reaction, attachment, and backup flows.
2. Verify replay, duplicate, out-of-order, skipped epoch, and corrupted
   ciphertext handling.
3. Remove/revoke a member/device and prove future content is unavailable after
   the protocol transition.
4. Exercise verified-device recovery and reject unverified/server-only reset.
5. Record interop vectors and client versions without plaintext artifacts.

Acceptance:

- Every supported flow is authenticated and decrypts only for intended
  current members.
- Replay/corruption/stale-epoch cases fail closed and recover as designed.
- Revoked devices cannot resume through stale local state.

## V07 — Verify UI and accessibility on real devices

Audit references: TEST-11, UI-13, UI-14.

Depends on: U08.

Objective:
Cover behavior that widget tests and desktop screenshots cannot establish.

Steps:

1. Define a core-flow matrix for supported Android/iOS versions and phone/
   tablet classes.
2. Run TalkBack/VoiceOver, large text, RTL, keyboard/focus, rotation, resume,
   notification, deep-link, and offline/reconnect checks.
3. Capture screenshots and concise issue notes without real account data.
4. Turn every reproducible defect into a focused automated regression where
   feasible.

Acceptance:

- Core auth, conversation, message, membership, safety, and settings flows are
  usable with assistive technology.
- Results name device, OS, build, and any remaining limitation.

## V08 — Assemble release evidence and external review

Audit references: SEC-08, TEST-07, TEST-08, TEST-09.

Depends on: V01, V02, V03, V04, V05, V06, V07, P08.

Objective:
Create one auditable decision package before declaring production E2EE ready.

Steps:

1. Collect required CI, race, fuzz, contract, restore, load, device, dependency,
   and license results with commit/toolchain identifiers.
2. Map the threat model and crypto protocol claims to evidence and remaining
   assumptions.
3. Obtain independent review of MLS integration, key storage, device linking,
   recovery, payload authentication, attachment crypto, and revocation.
4. Resolve critical/high findings or record a release-blocking decision.
5. Verify documentation and UI do not claim protections beyond the evidence.

Acceptance:

- Evidence is reproducible and tied to the exact release commit.
- All production blockers are closed; accepted residual risks have an owner
  and explicit rationale.
- C13 is the only card authorized to remove the fail-closed crypto gate.
