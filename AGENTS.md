# AGENTS.md

## User communication

- The user has difficulty reading long text. Keep updates and summaries very short.
- Lead with the result or blocker. Ask only for decisions that stop progress.

## Repository

Veritra is an AGPL-3.0-or-later, self-hosted, privacy-first messenger. The Go
server is a modular monolith with SQLite. The mobile app is Flutter for Android
and iOS. Rust/OpenMLS provides the crypto boundary.

Production messaging is intentionally unavailable until the mobile MLS path and
release evidence are complete.

Sequencing is fixed by decision D06 on the board: mobile ships first, desktop
(Windows and macOS) comes after that release as additional targets in this
repository, and embedded chat is deferred behind a product trigger. Do not start
desktop or embedding work, or add server-side plaintext paths to serve them.

## Non-negotiable boundaries

- The server stores ciphertext only for message bodies and attachments.
- Never log message text, request bodies, secrets, tokens, or ciphertext bodies.
- No server-side message-content search, telemetry, analytics, or admin plaintext access.
- Push data is generic: no message text or sender names.
- Incomplete crypto fails closed. Never bypass its release gate.
- Keep storage, crypto, push, uploads, realtime, and calls behind interfaces.
- Domain logic stays independent of HTTP handlers.

## How to work

1. Read `docs/board.md`.
2. Read `implementation/REMAINING_WORK.md`, the single execution queue and workflow.
3. Claim one eligible implementation task and read only its section plus the
   named consensus sections and files.
4. Confirm the task is still true before editing.
5. Make the smallest complete change and run the task's checks.
6. Update the board and consensus. Report changed files, checks, and blockers briefly.

Use judgment and match nearby code. Historical audits, plans, and superseded
assets live only in Git history; do not recover them unless a current card
links a specific revision and path. Prefer local, reversible actions. Ask
before destructive, external, release, or dependency changes.

Project documentation lives in `docs/`: `board.md` (status),
`audit-consensus.md` (audit decisions and implementation acceptance),
`overview.md` (architecture), `design.md` (visual spec), `operations.md`
(self-hosting), and `crypto.md` (the MLS boundary). The root `implementation/`
directory is the sole exception: it contains derived LLM execution contracts,
not authoritative product decisions.

Follow each task's model/advisor contract. The original executor still
implements the task after advice. Use multiple agents only for independent,
non-overlapping tasks. One coordinator owns board and consensus updates.

## Project gotchas

- `PM_CRYPTO_UNAVAILABLE` and `UnavailableCryptoService` are intentional gates.
- SQLite/local blobs are the supported single-node production design.
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
Run narrower checks from the assigned card first.
