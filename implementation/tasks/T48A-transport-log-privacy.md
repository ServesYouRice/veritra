# T48A — Transport lifecycle, route handling and log privacy

| Field | Contract |
|---|---|
| Consensus source | I48 lifecycle/privacy scope; LOG-12/SEC-06/SEC-09; L16/L17 |
| Routing snapshot (board wins) | Prepared |
| Risk | Medium feature/deployment conditional |
| Executor | Balanced+advisor |
| Advisor | Review teardown races and trusted-proxy threat model |
| Depends on | T32 |
| Blocks | T48B |
| Parallel safety | Coordinate server request logging with T29 and mobile sockets with T32 |

## Objective

Make socket connect/dispose awaitable, send close frames, normalize supported
subroutes, log matched patterns only and reject unsafe trusted-proxy identity.

## Read first

- `docs/audit-consensus.md` I48.
- Named source findings.
- Mobile sync/socket lifecycle; `server/internal/realtime/`, HTTP API routing,
  `server/internal/app/app.go`, client identity and tests.

## Invariants

- Logs contain no dynamic ID, token, endpoint, request/ciphertext body.
- Teardown leaves no authenticated connection established after disposal.
- Client identity trusts only explicitly safe proxy topology.

## Work

1. Add delayed-connect teardown regression and awaitable lifecycle.
2. Send appropriate close frame during drain/dispose.
3. Normalize supported trailing-slash routing deliberately.
4. Use route patterns with constant fallback in logs.
5. Validate trusted proxy ranges/hops and add spoof tests.

## Acceptance

- No socket leaks after delayed connect/dispose.
- Route/log sentinel tests contain no dynamic data.
- Proxy spoof attempts fail closed.

## Required checks

```sh
cd server && go test ./internal/realtime ./internal/httpapi ./internal/app
cd mobile && flutter test test/app_state_test.dart
```
