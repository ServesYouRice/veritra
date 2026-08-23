# Go Server Testing Gap Audit & Plan

> **Superseded input:** Do not execute this report directly. Its inventory and
> commands were not revision-bound. Use the reviewed
> [QA task pack](../implementation/tasks/test-followups/README.md).

## 1. System Overview & Architecture

The Veritra backend (`server/`) is a modular monolith written in Go (Go 1.25.12) backed by SQLite with WAL mode and single-writer mutual exclusion. It exposes HTTP REST APIs (`internal/httpapi/`), persistent WebSocket streams (`internal/realtime/`), WebRTC/TURN signaling (`internal/webrtc/`), APNs/FCM push dispatchers (`internal/push/`), and content/blob storage (`internal/uploads/`, `internal/storage/`).

Core architectural constraints:
- **Ciphertext Only**: Stored message payloads and attachments must never exist in plaintext on the server.
- **Zero-Knowledge Privacy**: No search indexes on message content, no telemetry, no admin decryption access.
- **Zero Plaintext Logging**: `log/slog` handlers must never record secrets, tokens, request bodies, or ciphertext buffers.
- **Single-Writer SQLite**: Single filesystem lock guarding database mutation consistency.

---

## 2. Current Test Coverage Inventory

### Existing Server Test Suites (24 files in `server/`)
- `cmd/messenger-server/main_test.go`: Server startup, flag parsing, and configuration loading.
- `internal/storage/sqlite_test.go` & `mls_message_store_test.go`: Comprehensive table CRUD, transaction isolation, account identity, and key package store.
- `internal/httpapi/api_test.go` (51 KB): Main HTTP route contract test suite verifying route registrations, authenticated endpoints, and JSON response shapes.
- `internal/httpapi/auth_handlers.go` & `internal/auth/auth_test.go`: Authentication token issuance, session refresh, and basic login backoff.
- `internal/realtime/websocket_test.go` & `internal/httpapi/websocket_contract_test.go`: WebSocket upgrade handshakes, authentication, and basic message echo/dispatch.
- `internal/app/rate_limit_test.go` & `blob_cleanup_test.go`: Rate limiter token bucket tests and background garbage collection ticks.
- `internal/uploads/local_test.go`: Disk upload chunking and SHA-256 digest validation.

---

## 3. Critical Testing Gaps Identified

### Gap SV-01: SQLite Single-Writer Lock Contention & Concurrent Crash Recovery
- **Defect**: Current storage tests run against in-memory or single-connection SQLite instances. There is no stress test simulating high concurrency (e.g., 100 concurrent writers and 500 concurrent readers) contesting the WAL lock or simulating abnormal server SIGKILL during an active multi-table transaction (e.g., key package claim + message fanout).
- **Risk**: `SQLITE_BUSY` lock timeouts returned to clients, partial state commits, or database lock file deadlocks requiring manual operator intervention.
- **Remediation Test Plan**:
  1. Create `server/internal/storage/concurrency_test.go`.
  2. Spawn 50 goroutines attempting simultaneous transactional writes (DMs, group creates, key package rotations).
  3. Verify retry-backoff logic under lock contention and verify database integrity via `PRAGMA integrity_check;`.

### Gap SV-02: WebSocket Slow Client Backpressure & Buffer Starvation
- **Defect**: `websocket_test.go` tests responsive clients. It lacks adversarial tests for: (a) slow consumers that never read socket frames, (b) half-open TCP connections (silent network loss), (c) flood attacks sending malformed frames, and (d) concurrent reconnection races during active sync event fanout.
- **Risk**: Server memory exhaustion from unbounded per-client outbound queues, goroutine leaks, or dropped sync events.
- **Remediation Test Plan**:
  1. Add `server/internal/realtime/backpressure_test.go`.
  2. Connect a simulated client with an unread TCP buffer and push 10,000 sync events.
  3. Verify the server drops or disconnects the slow client cleanly without affecting other connections or exhausting heap memory.

### Gap SV-03: Brute-Force Rate Limiting & Distributed IP Spoofing
- **Defect**: Rate limiting tests in `rate_limit_test.go` test unit token buckets with mock timestamps. They do not test HTTP integration behavior against distributed brute-force attacks across multiple IP aliases, `X-Forwarded-For` spoofing, or credential stuffing on `/api/v1/auth/login` and `/api/v1/setup`.
- **Risk**: Account credential brute-forcing, first-owner setup token compromise, and denial of service.
- **Remediation Test Plan**:
  1. Add `server/internal/httpapi/security_rate_limit_test.go`.
  2. Simulate 1,000 requests from spoofed proxy headers and verify that real client IP extraction logic (`TrustedProxy` configuration) enforces progressive delays (1s -> 2s -> 4s -> exponential backoff) and returns HTTP 429.

### Gap SV-04: Blob Storage Quota Enforcement & Orphaned Upload Cleanup
- **Defect**: Current upload tests verify clean single uploads. They lack coverage for: (a) aborted multipart uploads leaving temporary orphaned files on disk, (b) disk quota limit breaches mid-upload, (c) negative-byte or out-of-bounds HTTP Range request exploits, and (d) atomic blob deletion queue retries.
- **Risk**: Unbounded disk usage causing production server outage; unauthorized out-of-bounds byte disclosure.
- **Remediation Test Plan**:
  1. Add `server/internal/uploads/blob_lifecycle_test.go`.
  2. Initiate 100 uploads and abort midway; trigger garbage collection and assert zero orphaned temporary files remain.
  3. Send fuzz/adversarial `Range: bytes=X-Y` headers (e.g. `bytes=100-50`, `bytes=999999999-999999999`) and assert HTTP 416 (Range Not Satisfiable).

### Gap SV-05: WebRTC & TURN Ephemeral Credential Lifecycle
- **Defect**: `internal/webrtc/webrtc.go` and call sync handlers have minimal testing around HMAC-SHA1 ephemeral TURN credential generation, timestamp expiration, and call state cleanup when both peers abandon a signaling room.
- **Risk**: Leaked TURN relay bandwidth, stale call rooms occupying server memory.
- **Remediation Test Plan**:
  1. Add `server/internal/webrtc/turn_credentials_test.go`.
  2. Verify credentials expire exactly after configured TTL (e.g., 24 hours).
  3. Validate HMAC generation matches RFC 5766 TURN REST API spec.

### Gap SV-06: Static AST Linter for Zero Plaintext & Secret Logging
- **Defect**: Compliance with the AGENTS.md rule ("Never log message text, request bodies, secrets, tokens, or ciphertext bodies") is currently verified by human manual inspection. There is no automated test scanning the AST of all `log/slog` calls across the codebase.
- **Risk**: Accidental developer logging of auth headers, passwords, session tokens, or ciphertext in error paths.
- **Remediation Test Plan**:
  1. Create a dedicated test `server/internal/app/log_privacy_test.go` using Go `go/parser` and `go/ast`.
  2. Scan every `slog.Info`, `slog.Error`, `slog.Debug`, `slog.Warn` call site across `server/`.
  3. Assert no logged key matches forbidden patterns (`token`, `password`, `secret`, `ciphertext`, `body`, `payload`, `authorization`).

### Gap SV-07: Database Migration Forward & Rollback Idempotency
- **Defect**: Migrations in `server/migrations/` (0001 through 0023) are only tested in the forward direction on a clean database. There are no tests verifying rollback scripts or idempotency of reapplying migrations.
- **Risk**: Failed production upgrades leaving SQLite in an undefined, corrupted state with impossible rollback.
- **Remediation Test Plan**:
  1. Add `server/internal/storage/migration_lifecycle_test.go`.
  2. Apply migrations 0001->0023, insert test fixtures at each step, roll back to 0001, and re-apply to 0023.
  3. Verify zero data corruption and schema consistency.

---

## 4. Execution & Orchestration Specification

### Model & Advisor Assignment
- **Primary Executor Tier**: `Balanced+Advisor` (Standard HTTP, Storage, and Upload suites) / `Strong` (Concurrency, Migration, and Security Linter).
- **Advisor Requirement**: Strong Advisor review required for AST Privacy Linter and SQLite WAL concurrency test harness.

### XML Execution Prompt Contract

```xml
<role>You are the specialized Go Server Test Engineer for Veritra.</role>
<context>
Review server/internal/, server/migrations/, and testing/server_testing_gaps.md.
</context>
<invariants>
- Never log plaintext, ciphertext bodies, tokens, or secrets.
- All mutations must be transactional and thread-safe.
- Maintain compatibility with SQLite WAL single-writer model.
</invariants>
<instructions>
1. Implement AST log privacy scanner in server/internal/app/log_privacy_test.go.
2. Implement concurrent storage stress test in server/internal/storage/concurrency_test.go.
3. Implement migration lifecycle test in server/internal/storage/migration_lifecycle_test.go.
4. Run `go test ./...` and ensure all tests pass.
</instructions>
<handoff_format>
Task: Server Test Remediation
Result: complete | blocked
Checks: go test ./... output and AST privacy audit report
Advisor Checkpoint: Concurrency and AST linter findings
</handoff_format>
```
