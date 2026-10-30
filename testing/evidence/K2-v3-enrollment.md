# K2 server v3 enrollment slice - 2026-10-27

Status: server authentication slice implemented; coordinator independent review
found no blocking issues and its Linux snapshot passed all Go packages. This is
not completion of K2: history transfer resources, client wiring and importer
are not part of this evidence.

The separate migration `0038_device_links_v3.sql`, storage state machine and
explicit `/api/v1/device-links/v3` routes preserve v2. The exact wire contract
is in [K2-server-wire.md](../../docs/designs/K2-server-wire.md).

The recipient commits client-generated credential hashes in its signed proof.
Create/reserve/claim/approve/complete retry without issuing replacement secrets.
Polling is read-only. Completion retries use the exact current session token
hash, never rotation aliases, and cannot refresh or resurrect sessions. Source
operations are bound to the original device. Account/device invalidation and
retention remove enrollment context; both versions share pending-link quota.
Approved cancellation conflicts without silently revoking the new device.

Checks executed on Windows, from `server`:

```text
go test ./internal/storage ./internal/httpapi -run '^TestDeviceLink' -count=1
PASS
go test ./internal/storage -run TestDeviceLinkV3 -count=1
PASS
go test ./internal/storage ./internal/httpapi ./internal/app -run 'TestDeviceLinkV3|TestClassifyRoute|TestApplicationLogNeverContainsBodiesTokensOrCiphertext|TestDeviceLinkRequiresApprovalBeforeSession' -count=1
PASS (all three packages)
go vet ./internal/storage ./internal/httpapi ./internal/app
PASS
go test -p 1 ./internal/storage ./internal/httpapi -count=1
PASS (storage 32.368s, HTTP 20.897s)
git diff --check
PASS (line-ending warnings only)
```

The focused suite exercises immutable retries, tampered signed fields,
source-device authorization, concurrent lost-response completion, one
device/session/event, original link expiry, logout, current-token rotation
with a live alias, idle/absolute session expiry, revocation, account deletion,
retention, shared v2/v3 quota, response secrecy, privacy logs and malformed
large TTL rejection before duration conversion. HTTP tests build the signed
proof independently of the server helper.

The independently generated Rust/Python proof vector has 481 bytes and SHA256
`70e1a994b2e4e2878cdab80c38c26012177780bd93b2cacaf73c1699389d6f78`.
The Go test checks this exact vector, including the signed 64-byte-bounded
canonical device name.

The broader `go test ./internal/storage ./internal/httpapi -count=1` attempt
failed inside the Windows Go linker with a runtime access violation before
test execution. It is not recorded as a passing check. The serial retry above
and standalone vet passed. The coordinator's Linux snapshot passed all Go
packages; later changes here were tests only, so the snapshot does not cover
those additions. Full repository test/lint evidence belongs to the coordinator.

The final enrollment source and tests also pass the full Linux test/lint run
recorded in [`verification-2026-10-28.md`](verification-2026-10-28.md).
Migration0039 transfer-resource work is a separate slice.
