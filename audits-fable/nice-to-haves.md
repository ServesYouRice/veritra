# Nice-to-Haves — Veritra Audit (audits-fable)

> **Historical roadmap snapshot:** these recommendations were written against
> `c939f26`; several have since shipped. Use
> [`../audits-codex/README.md`](../audits-codex/README.md) for current release
> status.

Product, polish, developer-experience, architecture, and roadmap items. These are things that would make Veritra feel like a complete, trustworthy production product rather than a foundation. They are **not** blockers (blockers live in [logical-issues.md](logical-issues.md) and [security-issues.md](security-issues.md)) — but several are the difference between "technically works" and "people actually use it."

Grouped as requested:

1. High-impact nice-to-haves
2. Product polish
3. Developer experience improvements
4. Architecture / stack recommendations
5. Future roadmap ideas

---

## 1. High-impact nice-to-haves

These materially affect trust, usability, or retention. Do these soon after the blockers.

### NTH-1 — Push notifications (the make-or-break for a messenger)
- **Why:** Without push, messages arrive only while the app is foregrounded (LOG-2 reconnect churn aside). A messenger that can't wake you for a message is not competitive. Tracked as Tier-3.
- **What:** Implement `push.Provider` for at least FCM (Android) and APNs (iOS), plus UnifiedPush for degoogled users. Enforce the existing privacy contract: `GenericPayload` only — no sender name, no message text (there's already a `push_test.go` guarding the generic payload; extend it to fail if forbidden fields appear).
- **Depends on:** OPS-1 platform folders, SEC-8 endpoint validation.

### NTH-2 — Identity you can actually see and verify
- **Why:** Users currently exchange opaque `acct_<hex>` IDs (UI-6, UI-18). Real messengers show usernames/display names/avatars and offer safety-number verification.
- **What:** Display names + avatars (encrypted or public-metadata), show the current user's username, a people picker over search, and key-fingerprint/safety-number comparison for contacts (the device-link flow already has the verification-code primitive to build on).

### NTH-3 — Message delivery/read status and typing that works
- **Why:** Read receipts and typing exist server-side but drive no UI (UI-8, UI-15); typing lacks a membership check (SEC-2). Delivery/read status is a baseline expectation.
- **What:** Wire read receipts into per-message status and chat-list unread badges; surface typing indicators in the chat screen; fix SEC-2 first.

### NTH-4 — Attachments end-to-end (upload + download + preview)
- **Why:** The upload endpoints are write-only (LOG-3) and the button is dead (UI-11). Sharing photos/files is table stakes.
- **What:** Client-side encryption of attachments (blocked on LOG-0), download endpoints, thumbnails/previews, and quotas (SEC-4).

### NTH-5 — Encrypted backup & restore that a user can trust
- **Why:** Backup blobs are write-only and unrecoverable (LOG-3), and DB/blob backups can desync (OPS-3). "Recovery" is shown as coming-soon in Settings.
- **What:** A real recovery-key flow (generate, store offline, restore on a new device), with a tested round-trip. This is what protects users from losing their history when they lose a phone.

### NTH-6 — Onboarding that explains the model
- **Why:** Veritra's model (invite-only, device-linking, no phone numbers, exact-username search) is unusual. New users need guidance, and the connect screen currently defaults to the wrong mode (UI-3).
- **What:** A short first-run explainer, setup-status-aware mode selection, and inline help on the password/username rules (UI-2).

---

## 2. Product polish

Smaller details that were likely overlooked; each removes a rough edge.

- **NTH-7 — Consistent branding.** Resolve the `private-messenger` / "Private Messenger" / "Veritra" split (OPS-14); default instance name should be "Veritra".
- **NTH-8 — Chat-list recency & previews** (UI-8): order by last activity, show last-message time.
- **NTH-9 — Message history loading** (LOG-15): scroll-up pagination is implemented on the server but not the client.
- **NTH-10 — Search that leads somewhere** (LOG-16): make account/channel results actionable.
- **NTH-11 — Clear error copy everywhere** (UI-1): never show `StateError`/raw codes.
- **NTH-12 — Persist session-created records** (UI-7): invites/communities shouldn't vanish on restart.
- **NTH-13 — Empty vs. loading distinction** (UI-4): stop showing "nothing here" while loading.
- **NTH-14 — Message actions:** copy/edit/delete/react/reply UI (server supports edit/delete/reactions/reply already; the client exposes almost none of it).
- **NTH-15 — Retention clarity** (LOG-12, UI-20): state whether disappearing applies retroactively, and confirm the change.
- **NTH-16 — Search clear button and result counts** (UI-17).
- **NTH-17 — Accessibility polish** (UI-12): semantics labels, screen-reader pass, dynamic type.
- **NTH-18 — Deep-link handling:** the app mints `veritra://device-link?code=…` URIs but nothing registers/handles the scheme; wire it for one-tap linking.

---

## 3. Developer experience improvements

- **NTH-19 — Coverage in CI + a ratchet** (TEST-8): make untested code visible.
- **NTH-20 — E2E/integration harness** (TEST-9): the highest-leverage safety net; also serves as living documentation of the flows.
- **NTH-21 — API contract source of truth** (TEST-5): an OpenAPI/JSON schema generated from or validated against both Go handlers and Dart models. Kills the client/server drift class (LOG-1, LOG-16) permanently.
- **NTH-22 — Vuln scanning gated in CI** (OPS-11): `govulncheck`, `cargo audit`, Dart dependency review, plus a committed Dependabot/renovate config.
- **NTH-23 — Version stamping & release pipeline** (OPS-13): embed version/commit in the binary; publish container images on tags.
- **NTH-24 — Local dev ergonomics:** a `TestOnlyCryptoService`-backed "demo mode" build flavor so contributors can run the full app end-to-end without waiting on real crypto. Document it loudly as non-production.
- **NTH-25 — Structured logging options** (OPS-12): env-driven log level + JSON handler.
- **NTH-26 — Architecture decision records are good — keep them current.** The ADRs (`docs/adrs/`) are a genuine strength; add ADRs for the crypto library choice and push stack once decided.
- **NTH-27 — Reduce global mutable state in the client** (LOG-24): per-feature state controllers to cut the spurious-disabled-button / misplaced-error class of bugs before the UI grows.

---

## 4. Architecture / stack recommendations

The current architecture (Go modular monolith + SQLite + local blobs + in-memory hub + Flutter) is well-chosen for the stated target (self-hosted, small-to-medium single instances). Recommendations are about preserving that while removing ceilings:

- **NTH-28 — Keep the monolith; formalize the crypto boundary.** The `cryptoapi.ClientCrypto` interface + Rust FFI boundary is the right seam. When binding OpenMLS, keep the server strictly ciphertext-blind (it already is) so the trust model doesn't regress. This is the one place to be conservative.
- **NTH-29 — Introduce a storage abstraction for blobs.** `uploads.Store` is an interface (good). Add an S3/object-store implementation option so operators who outgrow local disk (the SEC-4 / OPS-3 pain point) can offload blobs without touching the DB. Local remains the default.
- **NTH-30 — Consider a Postgres option behind the storage interface** for operators who need concurrency beyond SQLite's single writer (PERF ceiling). ADR-0003 chose SQLite deliberately; this is an *optional* backend, not a replacement. Only worth it if multi-hundred-write/sec instances become a real use case.
- **NTH-31 — Move realtime toward durable-body delivery.** The Hub is best-effort with DB catch-up (a sound contract). Delivering event bodies over the socket (not just a nudge to re-poll `/sync/events`) would cut the highest-frequency read (PERF-3/PERF-4). Still no external broker needed at target scale.
- **NTH-32 — Don't add microservices, Kubernetes, or a message broker** for this target. They'd add operational burden that contradicts the "single binary, self-hostable" value proposition. Revisit only if a hosted multi-tenant offering appears (roadmap).
- **NTH-33 — Flutter is the right client choice** given single-codebase iOS/Android; the near-zero-dependency approach (only `flutter_secure_storage`) is admirable and worth preserving. Add `flutter_rust_bridge` (or equivalent) only for the crypto FFI.

---

## 5. Future roadmap ideas

Rough sequencing after a first production release:

- **Near term (post-launch hardening):** admin/moderation surface + audit-log viewer (OPS-9), storage quotas & usage UI (SEC-4), account-deletion completeness (SEC-6), session lifetime policy (SEC-5), desktop client (Flutter desktop targets already free with the codebase).
- **Medium term:** 1:1 voice/video calls (the `webrtc.SignalingService` + `call_sessions` scaffolding exists; needs Pion/LiveKit media, per Plan.md), group calls, message search over locally-decrypted content (server stays blind), multi-language / i18n (currently English-only, no `intl`), rich message types (replies/threads UI — data model already supports `reply_to_id`/`thread_root_id`).
- **Longer term:** federation or multi-instance interop, hosted/managed offering (would change the architecture calculus in NTH-30/32), disappearing-message parity with Signal (per-message timers), self-destructing media, sealed-sender-style metadata minimization, formal third-party crypto/security audit before marketing E2EE guarantees.
- **Trust & transparency:** publish the threat model (`docs/threat-model.md` exists — surface it), a security.txt, a bug-bounty or coordinated-disclosure process (SECURITY.md exists — build on it), and reproducible builds so users can verify the client matches the source.

---

## Closing note

The most valuable "nice-to-have" is honesty about state, and this repo already has it: loud TODOs, fail-closed stubs, ADRs, and prior audit logs (`WORK_IN_PROGRESS.md`, `Plan.md`). Preserving that discipline through the crypto integration — the moment where it's tempting to cut corners — is what will make Veritra trustworthy. Everything in this file is downstream of first shipping a product that actually encrypts and delivers a message.
