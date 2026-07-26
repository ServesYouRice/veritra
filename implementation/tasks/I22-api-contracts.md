# I22 — Add live API contracts

Goal: detect route, status, pagination, and JSON drift between Go and Flutter.

Read:

- server route registration and handler tests
- `mobile/lib/core/api_client.dart`, `mobile/lib/core/models.dart`
- `implementation/archive/2026-07-26/docs/api.md` as historical reference only

Do:

1. Start a real migrated test server with synthetic accounts and ciphertext envelopes.
2. Exercise every Flutter-used route, including error and pagination shapes.
3. Decode responses with the real Dart models.
4. Add the contract suite to the normal CI gate.
5. Update stale historical docs only by creating a focused active card; code is authoritative.

Done when: changing a route/method/status/required field breaks one clear contract test.

Verify: server tests, Dart contract tests, then aggregate test script.

Fixtures must not contain real message or attachment plaintext.
