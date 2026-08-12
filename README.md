<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/branding/concept-06/veritra-wordmark-dark.svg">
  <img src="docs/branding/concept-06/veritra-wordmark.svg" alt="Veritra" width="380">
</picture>

Veritra is an open-source, self-hostable, privacy-first messaging app. The first product shape is closer to WhatsApp or Signal than Discord: direct messages, private group chats, lightweight communities, optional channels, simple roles, and end-to-end encrypted message envelopes.

This repository is an initial MVP foundation with fail-closed boundaries around unfinished production features. See [`docs/board.md`](docs/board.md) for the single current work list, and [`docs/overview.md`](docs/overview.md) for an architecture walkthrough.

## Current Status

- License: AGPL-3.0-or-later.
- Server: Go modular monolith, single binary target, SQLite-first.
- Mobile: Flutter client for Android and iOS.
- Crypto: server-side ciphertext-only model plus MLS/OpenMLS integration boundary. Production message crypto is not complete.
- Hosting: single binary goal plus Docker Compose and Caddy examples.

## Roadmap

One product, one repository, three phases — decided as **D06** on the board.

1. **Mobile** — Android and iOS. This is the entire first release, and the current work.
2. **Desktop** — Windows and macOS, after that release. Additional Flutter targets in this repository reusing the same reviewed Rust crypto core, not a fork. A self-hosted internal-network deployment is this plus the same server.
3. **Embedded chat** — deferred. If embedded conversations must stay end-to-end encrypted, the deliverable is a client SDK rather than a drop-in widget, because the server holds no key it could hand one. That question has to be answered before any work starts.

Triggers and rationale are in [`docs/board.md`](docs/board.md#roadmap-after-release).

## Quickstart

Local Go, Flutter, and Rust toolchains are optional. The preferred path is Dockerized checks:

```sh
./scripts/test.sh
./scripts/lint.sh
```

On Windows PowerShell:

```powershell
.\scripts\test.ps1
.\scripts\lint.ps1
```

If local script execution is disabled:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\lint.ps1
```

If Go is installed locally:

```sh
cd server
go run ./cmd/messenger-server migrate
go run ./cmd/messenger-server serve
```

Then open:

```text
http://localhost:8080/setup
```

The browser page is a setup notice only until production client crypto is wired. Owner setup must come from a client that can generate a real device key package. Remote first-owner setup also requires a high-entropy `PRIVATE_MESSENGER_SETUP_TOKEN`; tokenless setup is loopback-only.

Default data lives under `./data` unless `PRIVATE_MESSENGER_DATA_DIR` is set.

## Security Defaults

- Invite-only registration by default.
- No phone numbers.
- No telemetry or analytics.
- No request-body logging.
- No message-content logs.
- Server stores encrypted message envelopes and encrypted attachment blobs only.
- Server-side search over message contents is forbidden.
- Admins cannot silently read DMs, private groups, private channels, or attachment contents.

## Repository Layout

```text
server/     Go server, migrations, setup notice
mobile/     Flutter client for Android and iOS
crypto/     Rust crypto boundary
deploy/     Docker Compose, Caddy, systemd
scripts/    Dockerized development commands
docs/       All documentation (see below)
```

Every document lives in [`docs/`](docs/):

| File | What it is |
| --- | --- |
| [`board.md`](docs/board.md) | **The board.** Active cards, decisions, release evidence, roadmap, review brief |
| [`overview.md`](docs/overview.md) | Architecture walkthrough — what it is, how it fits together, how to run it |
| [`design.md`](docs/design.md) | The K2 · Bone palette, per-screen spec, and how it landed in Flutter |
| [`operations.md`](docs/operations.md) | Self-hosting: setup, secrets, upgrade, rollback, restore drill |
| [`crypto.md`](docs/crypto.md) | The MLS/OpenMLS boundary and its C ABI |
| [`branding/`](docs/branding/) | Marks, wordmarks, icons |
| [`archive/`](docs/archive/) | Read-only history. Do not load unless a card links a specific file |

Two documents are authoritative and should be read before changing anything:
[`AGENTS.md`](AGENTS.md) for the non-negotiable boundaries, and
[`docs/board.md`](docs/board.md) for what is actually being worked on.
Everything else describes; those two decide.

## Important Caveat

The MVP foundation is compatible with E2EE everywhere, but full production cryptography is not complete. Any feature that would require plaintext on the server is rejected or documented as future work.

See [`docs/board.md`](docs/board.md) for release blockers,
user decisions, and deferred work.
