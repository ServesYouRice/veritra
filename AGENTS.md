# AGENTS.md

## User communication

- The user has difficulty reading long text. Keep updates and summaries very short.
- Lead with the result or blocker. Ask only for decisions that stop progress.

## Repository

Veritra is an AGPL-3.0-or-later, self-hosted, privacy-first messenger. The Go
server is a modular monolith with SQLite. The mobile app is Flutter for Android
and iOS. Rust/OpenMLS provides the crypto boundary.

Production messaging stays unavailable in release builds (`mobile/lib/main.dart`)
until the mobile MLS path, independent review and release evidence are complete.

Sequencing is set by decision D10 in [`STATE.md`](STATE.md) (it replaces D06's ordering):
working local demos come first, on Android, iOS, Windows and Linux. Demo builds
use the real MLS path only through `mobile/lib/main_demo.dart` (D11), with
loopback-only HTTP (D12). Desktop is additional Flutter targets in this
repository, never a fork. Independent review, signing and real-device evidence
wait until all three roadmap phases are done. Embedded chat stays deferred and,
when built, stays end-to-end encrypted (D19). Never add server-side plaintext
paths for any of this, and never ship a demo build as a release.

## Governing principle

Set by the owner (hosting handbook, 2026-10-04): build Veritra as a full,
full-featured product with best practices and the right technology, not as a
demo or the cheapest option for now. Build what the product's promise depends
on properly now; where something only matters under load, build the seam and
leave it switched off. Do not add technology the product would never need.
The release gate below is a safety rule, not a "do not build" list.

## Non-negotiable boundaries

- The server stores ciphertext only for message bodies and attachments.
- Never log message text, request bodies, secrets, tokens, or ciphertext bodies.
- No server-side message-content search, telemetry, analytics, or admin plaintext access.
- Push data is generic: no message text or sender names.
- Incomplete crypto fails closed. Never bypass its release gate.
- Keep storage, crypto, push, uploads, realtime, and calls behind interfaces.
- Domain logic stays independent of HTTP handlers.

## How to work

1. Read [`STATE.md`](STATE.md): status, standing decisions, open work, gates.
2. Pick one open item and confirm it is still true against the code.
3. Make the smallest complete change, with tests, and run the narrow checks
   first, then `scripts/test` and `scripts/lint`.
4. Update `STATE.md` when its truth changes, and put measurements or evidence
   in `testing/evidence/`. Report changed files, checks, and blockers briefly.

Use judgment and match nearby code. Historical audits, the old board, the
audit consensus and task contracts live only in Git history (`docs/board.md`,
`docs/audit-consensus.md`, `implementation/REMAINING_WORK.md` at `d2d9eb8`);
do not recover them unless `STATE.md` cites a revision and path. Prefer local,
reversible actions. Ask before destructive, external, release, or dependency
changes.

Project documentation lives in `docs/`: `overview.md` (architecture),
`design.md` (visual spec), `operations.md` (self-hosting and deployment),
`crypto.md` (the MLS boundary and its change log), `security-review.md` (the
independent review brief and signed-device matrix), `demo.md` (local demos)
and `sdk.md` (phase 3 outline).

Get an independent second opinion (a review agent) before a security, MLS
ordering, migration, recovery, credential, platform-policy, artifact-trust or
release-gate decision. Use multiple agents only for independent,
non-overlapping work; one coordinator owns `STATE.md`.

## Project gotchas

- `PM_CRYPTO_UNAVAILABLE` and `UnavailableCryptoService` are intentional gates.
- SQLite/local blobs are the default single-node production design. Optional
  PostgreSQL or S3-compatible backends may be added later behind the existing
  storage interfaces; SQLite and local files stay the default.
- New dependencies need license review and `THIRD_PARTY_NOTICES.md` updates.
- Use `log/slog`, explicit errors, and context cancellation in Go.
- Preserve unrelated user changes in a dirty worktree.

## Commands

Preferred:

```powershell
.\scripts\test.ps1
.\scripts\lint.ps1
```

Linux equivalents: `./scripts/test.sh` and `./scripts/lint.sh`.
Run narrower checks for the area you changed first.
