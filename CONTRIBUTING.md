# Contributing

Contributions are welcome if they preserve the privacy and security model.

## Before you start

Read [`AGENTS.md`](AGENTS.md). It holds the non-negotiable boundaries — no
server-side plaintext, no telemetry, no message-content search — and they apply
to every contribution. Read [`docs/board.md`](docs/board.md) for what is
actually being worked on.

## Requirements

- License contributions under AGPL-3.0-or-later.
- Do not import code without license review; update `THIRD_PARTY_NOTICES.md` for new dependencies.
- Add or update tests for auth, devices, permissions, encrypted envelope persistence, and migration changes.

## Development

Use Dockerized scripts by default:

```sh
./scripts/test.sh
./scripts/lint.sh
```

Windows equivalents are `.\scripts\test.ps1` and `.\scripts\lint.ps1`.

