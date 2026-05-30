# AGENTS.md

## About the user
The user has a medical condition where they have difficulty reading big walls of text. They prefer extremely short and concise messages explaining current problems and summaries.

## Project Overview

Private Messenger is an AGPL-3.0-or-later, self-hostable, privacy-first messenger. The server is a Go modular monolith with SQLite by default. The mobile app is Flutter-first for Android and iOS. Server code must preserve end-to-end encryption boundaries and never require plaintext message bodies.

## Architecture Rules

- Domain logic must not depend on HTTP handlers.
- Storage, crypto, push, upload, realtime, and call signaling stay behind interfaces.
- Server persistence stores ciphertext only for message bodies and attachment contents.
- No server-side message-content search.
- No telemetry or analytics.
- No request-body logs.
- Use explicit errors and context cancellation in Go.
- Avoid global mutable state and cyclic dependencies.

## Code Style

- Prefer boring, small, testable functions.
- Keep module boundaries clear.
- Use `log/slog` with privacy-safe fields only.
- Add comments only for non-obvious security or protocol decisions.
- New dependencies require license review and an entry in `THIRD_PARTY_NOTICES.md`.

## Commands

Dockerized commands are the default because local Go/Flutter/Rust may not be installed:

```sh
./scripts/test.sh
./scripts/lint.sh
./scripts/dev.sh
```

Local equivalents:

```sh
cd server && go test ./...
cd server && go vet ./...
cd mobile && flutter test
```

## Privacy/Security Non-Negotiables

- Never store plaintext message bodies or plaintext attachment contents.
- Never add fixtures containing real plaintext message examples to server storage tests.
- Never log secrets, tokens, request bodies, ciphertext contents, or message text.
- Incomplete crypto must fail closed and be marked as non-production.
- Push payloads must be generic and must not include message text or sender names.
- Admin features must not create silent access to private content.

## Adding Modules

Add a package under `server/internal/<module>` with:

- domain-facing interfaces where appropriate
- storage implementation behind `server/internal/storage`
- handler wiring in `server/internal/httpapi`
- focused unit tests
- privacy/security notes in docs if behavior touches message content, keys, auth, push, recovery, or logs

