# Veritra

Veritra is an open-source, self-hostable, privacy-first messaging app. The first product shape is closer to WhatsApp or Signal than Discord: direct messages, private group chats, lightweight communities, optional channels, simple roles, and end-to-end encrypted message envelopes.

This repository is an initial MVP foundation. It intentionally includes safe boundaries and loud TODOs where a complete production implementation would require more time, especially cryptography, push delivery, and WebRTC media.

## Current Status

- License: AGPL-3.0-or-later.
- Server: Go modular monolith, single binary target, SQLite-first.
- Mobile: Flutter shell for Android and iOS architecture.
- Crypto: server-side ciphertext-only model plus MLS/OpenMLS integration boundary. Production message crypto is not complete.
- Hosting: single binary goal plus Docker Compose and Caddy examples.

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
server/   Go server, migrations, setup notice
mobile/   Flutter mobile client shell
crypto/   Rust crypto boundary and docs
deploy/   Docker Compose, Caddy, systemd
docs/     Architecture, threat model, ADRs
scripts/  Dockerized development commands
```

## Important Caveat

The MVP foundation is compatible with E2EE everywhere, but full production cryptography is not complete. Any feature that would require plaintext on the server is rejected or documented as future work.
