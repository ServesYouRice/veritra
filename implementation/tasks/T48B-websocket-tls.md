# T48B — WebSocket parser and self-hosted LAN TLS assurance

| Field | Contract |
|---|---|
| Consensus source | I48 assurance scope; S7/S8 |
| Routing snapshot (board wins) | Prepared |
| Risk | Medium security/deployment conditional |
| Executor | Strong |
| Advisor | Required before parser replacement or trust-model choice |
| Depends on | T48A |
| Blocks | Supported realtime/LAN deployment claim |
| Parallel safety | One owner for parser/fuzz evidence and documented TLS trust path |

## Objective

Keep the hand-written WebSocket surface only with sufficient adversarial/fuzz
evidence, and provide a documented mobile TLS trust path for supported LAN installs.

## Read first

- `docs/audit-consensus.md` I48 and reconciled source IDs S7/S8.
- `server/internal/realtime/websocket.go` and tests, Caddy config, mobile
  networking/platform configuration and operations docs.

## Invariants

- No blanket TLS verification bypass, permissive certificate callback or TOFU
  without an approved threat model.
- A replacement dependency needs license/notices and compatibility review.
- Parser input stays bounded before authentication and after upgrade.

## Work

1. Define parser limits and add malformed/fragment/control-frame fuzz coverage.
2. Run Autobahn or equivalent protocol evidence against supported behavior.
3. Decide from evidence whether to retain or replace parser.
4. Document and implement supported CA/certificate provisioning for LAN clients.

## Acceptance

- Malformed frames remain bounded and protocol suite passes documented cases.
- Real mobile client establishes the supported LAN TLS path without bypass.
- Any dependency change passes notices/license/security review.

## Required checks

```sh
cd server && go test ./internal/realtime ./internal/httpapi
cd server && go test -fuzz=Fuzz -fuzztime=30s ./internal/realtime
```
