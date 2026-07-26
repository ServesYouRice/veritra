# I23 — Test proxy and WebSocket adversarial paths

Goal: prove the supported realtime path handles untrusted frames and proxy identity safely.

Read:

- realtime/WebSocket parser and hub code
- trusted proxy implementation from I06
- Caddy configuration and related tests

Do:

1. Add fuzz/conformance coverage for masking, fragmentation, sizes, control frames, UTF-8, close, and slow clients.
2. Test origin, authorization-before-upgrade, expiry, cancellation, and shutdown.
3. Run connection-limit tests through the supported proxy topology.
4. If the custom parser remains risky, propose one maintained replacement with license impact; request approval before adding it.

Done when: malformed inputs close safely, limits use trusted client identity, and tests pass under the race detector.

Verify:

```powershell
Push-Location server; go test -race ./internal/realtime/... ./internal/httpapi/...; Pop-Location
```

Never log frames, tokens, ciphertext payloads, or message data.
