# Plan 09 — Deferred product roadmap

These items are useful but do not precede the production/privacy blockers in
Plans 00–08. Do not assign a roadmap item until its trigger and product design
are approved.

## R01 — Profiles and avatars

Audit references: NICE-01, NICE-02.

Trigger: M04 identity models are stable and an avatar privacy/storage design is
approved.

Scope:
Add optional display metadata and encrypted or explicitly public avatar
semantics. Define abuse, deletion, cache, size, and accessibility behavior
before implementation.

## R02 — Local message-content search

Audit reference: NICE-03.

Depends on: C02, C03, C09.

Trigger: encrypted database and content schema are production-ready.

Scope:
Index decrypted content only on the client inside the encrypted local database.
Never add server-side content search, plaintext analytics, or search telemetry.

## R03 — Operator console

Audit reference: NICE-04.

Depends on: D05.

Trigger: operator roles, audit minimization, and protected management transport
are designed.

Scope:
Expose health, configuration, version, quota, backup, and aggregate abuse
controls. Never provide silent access to message content or crypto keys.

## R04 — Guided onboarding and invite links

Audit references: NICE-05, NICE-06.

Trigger: server URL, instance identity, enrollment, and expiry semantics are
stable.

Scope:
Use a versioned HTTPS/universal-link or QR format with explicit instance
identity and short-lived enrollment material. Do not invent a custom URI until
platform routing and phishing behavior are reviewed.

## R05 — Multi-account support

Audit reference: NICE-08.

Depends on: C02, C05.

Trigger: per-account key/storage isolation and notification routing are proven.

Scope:
Isolate database keys, MLS state, credentials, push routing, background work,
and wipe/logout operations for each account.

## R06 — Conversation organization and drafts

Audit references: NICE-10, NICE-11.

Depends on: C03.

Trigger: encrypted local persistence and sync state are stable.

Scope:
Add local encrypted drafts, archive/pin/folder state, and deterministic merge
rules. Decide which metadata is device-local versus server-synchronized.

## R07 — Passkeys and stronger account authentication

Audit reference: NICE-13.

Trigger: enrollment, recovery, and multi-device threat models are reviewed
together.

Scope:
Add phishing-resistant authentication without treating account authentication
as a replacement for message-key/device verification.

## R08 — Calls

Audit reference: NICE-14.

Trigger: messaging crypto, membership removal, and device identity have passed
V06/V08.

Scope:
Design authenticated call signaling, media E2EE, TURN credentials, permissions,
abuse controls, background behavior, and platform testing as a separate threat
model.

## R09 — Desktop clients

Audit reference: NICE-15.

Trigger: mobile crypto core and packaging are stable and reusable.

Scope:
Reuse the reviewed native crypto core while separately designing desktop key
storage, updates, signing, sandboxing, and multi-instance behavior.

## R10 — Protocol agility and post-quantum readiness

Audit reference: NICE-16.

Depends on: S03, C13.

Trigger: the initial approved MLS suite ships and standards/library support is
interoperable.

Scope:
Version authenticated payloads and supported suites deliberately. Do not add
an unreviewed custom hybrid or claim post-quantum protection prematurely.

## R11 — Encrypted content extensions

Depends on: C09, C10.

Trigger: authenticated payload versioning and encrypted attachment streaming
are stable.

Scope:
Design client-generated encrypted link previews and voice notes as separate
bounded tasks. Fetch previews client-side with SSRF/privacy controls, and keep
preview/media contents opaque to the server. Split this card before work.

## R12 — Community moderation reports

Depends on: M02, C09.

Trigger: community roles, removal, and authenticated payload schemas are
stable.

Scope:
Design member freeze and voluntary client-side re-encryption of reported
content to named moderators. Never give moderators or admins silent access to
unreported plaintext.

## R13 — Client-side imports

Depends on: C02, C09.

Trigger: encrypted local schema, authenticated payload mapping, and deletion
semantics are stable.

Scope:
Import supported Signal/WhatsApp export data entirely on the client into the
encrypted local store. Define provenance, duplicate handling, attachment
limits, and explicit non-upload behavior.

## R14 — Machine-readable API generation

Depends on: V04.

Trigger: the live API contract suite is stable and measured maintenance cost
justifies a generator.

Scope:
Select an OpenAPI or equivalent source of truth, review generator dependencies
and licenses, generate/check the Dart model/client surface, and prevent manual
and generated definitions from drifting.

## R15 — Contributor-experience cleanup

Depends on: B04, V01.

Trigger: blocker work is green and a cleanup diff will not churn active crypto
or storage seams.

Scope:
Centralize documented error codes, remove verified dead wrappers, add targeted
coverage reporting, and evaluate a devcontainer or Nix environment. Split each
independent change into its own card and review new dependencies/licenses.

## R16 — Native notification providers

Depends on: C09, U07.

Trigger: generic authenticated notification hints and background crypto
behavior are proven on real devices.

Scope:
Add APNs and any supported Android distributor behind the push interface.
Payloads remain generic: no sender name, message text, attachment name, or
conversation title. Include permission, token rotation, delivery failure,
privacy disclosure, and real-device tests.

## Infrastructure explicitly not planned

PostgreSQL, S3-compatible storage, Redis, NATS, and federation are not current
requirements. Reconsider one only when P01/P08 demonstrate a concrete limit or
an approved product requirement demands it. Any new dependency needs a license
review, THIRD_PARTY_NOTICES.md entry, migration/rollback plan, and privacy
analysis.
