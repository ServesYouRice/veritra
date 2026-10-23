# T37C — Password hashing and session lifetime evidence

Base commit: `89a437e`. Date: 2026-10-23. Toolchain: go1.26.10 linux/amd64,
`golang.org/x/crypto` v0.57.0 (already a dependency; `argon2` is in that
module, so nothing new was added). Host: 4 vCPU "Intel(R) Xeon(R) Processor",
Linux 6.18, 16 GiB RAM, shared with five other build/test workers during the
run, so absolute times are pessimistic and noisy.

## Chosen parameters

| Setting | Value | Why |
|---|---|---|
| Algorithm | Argon2id, version 19 (0x13) | Owner hosting standard; RFC 9106 |
| Memory | 65536 KiB (64 MiB) | RFC 9106 low-memory option's memory; above the OWASP 19 MiB minimum |
| Passes | 2 | Between OWASP minimum (t=2 at 19 MiB) and RFC 9106 (t=3) |
| Lanes | 1 | One core per login; small VPSes have 1-2 vCPU |
| Salt / tag | 16 / 32 bytes | RFC 9106 |
| Encoding | `$argon2id$v=19$m=65536,t=2,p=1$<salt>$<tag>` (PHC, unpadded std base64) | Self-describing, so parameters can change later with rehash-on-success |
| Concurrency | 3 process-wide slots, 1 reserved for signed-in callers; 5 s wait, then 503 `password_hashing_busy` | Bounds memory; anonymous floods cannot block reauthentication |

## Measurements

Raw primitives, `GOMAXPROCS=1`, 20 iterations x 3 runs, median (range):

| Primitive | ms/op | Memory/op |
|---|---|---|
| Argon2id m=19 MiB t=2 p=1 (OWASP minimum) | 19.7 (19.4-20.3) | 19 MiB |
| Argon2id m=46 MiB t=1 p=1 (OWASP) | 29.7 (29.4-29.8) | 46 MiB |
| Argon2id m=32 MiB t=2 p=1 | 37.0 (35.4-37.9) | 32 MiB |
| Argon2id m=64 MiB t=1 p=1 | 42.7 (42.2-43.4) | 64 MiB |
| **Argon2id m=64 MiB t=2 p=1 (chosen)** | **86.0 (81.4-87.6)** | **64 MiB** |
| Argon2id m=64 MiB t=3 p=4 (RFC 9106 second option, 1 core) | 136.2 (134.5-136.8) | 64 MiB |
| bcrypt cost 10 (legacy) | 56.0 (55.6-56.3) | 5 KiB |
| bcrypt cost 12 | 218.7 (218.6-220.1) | 5 KiB |

Full verification path (`BenchmarkPasswordVerification` in
`server/internal/auth/auth_test.go`, slot acquisition included), 20
iterations x 3 runs, median (range), 67,111,224 B/op (64 MiB) in every row:

| Case | `GOMAXPROCS=1` ms/op | `GOMAXPROCS=4` ms/op |
|---|---|---|
| Argon2id account | 93.0 (90.7-100.1) | 104.5 (96.7-107.0) |
| Unknown account | 92.6 (91.2-123.1) | 91.0 (88.2-91.1) |
| Argon2id account while bcrypt hashes remain | 152.6 (151.6-154.3) | 146.6 (145.5-151.2) |
| Unknown account while bcrypt hashes remain | 145.6 (144.1-150.6) | 148.8 (145.6-160.9) |
| bcrypt-10 account (legacy) | 144.0 (143.1-164.6) | 163.5 (159.5-165.0) |

One verification is about 90-100 ms once no bcrypt hash remains and about
145-155 ms while any does, under the 250 ms target with headroom even on
this contended host. If a target VPS measures one verification above about
200 ms, lower the pass count to 1 (about 43 ms here); stored hashes migrate
on the next sign-in.

Burst: 64 concurrent verifications (48 anonymous, 16 signed-in, bcrypt
present), `GOMAXPROCS=2`:

| Runtime limit | Completed | 503 busy after 5 s | Peak heap | Peak RSS (VmHWM) |
|---|---|---|---|---|
| none (GOGC=100) | 49 | 15 | 384 MiB | 390 MiB |
| `GOMEMLIMIT=256MiB` | 57 | 7 | 256 MiB | 262 MiB |

Live hash buffers never exceed 3 x 64 MiB; without a limit the garbage
collector lets the heap reach about twice that. Unbounded, the same burst
would ask for 64 x 64 MiB = 4 GiB. Deployments in a 1 GiB container should set
`GOMEMLIMIT` (for example 768MiB).

## Constant work and migration

- While any live (not deleted) account still has a bcrypt hash, every
  verification does one bcrypt and one Argon2id computation, whether the
  account exists, is legacy or migrated, and whether the password matches.
  When none remain, every verification does one Argon2id computation.
  `TestVerificationWorkDoesNotDependOnAccountOrOutcome` counts the
  primitives for each case instead of timing them.
- The instance-wide "bcrypt present" state is read once (first sign-in after
  start) and again after each migration. On a probe error it assumes present.
- A bcrypt hash is replaced only after password and device secret both pass
  (`TestLoginMigratesALegacyBcryptHashOnlyAfterFullSuccess`), with a
  compare-and-set on the old hash. The password is never stored or logged.
- Known residuals: a hash created with older Argon2id parameters, or a bcrypt
  hash at a cost other than `PRIVATE_MESSENGER_BCRYPT_COST`, verifies in a
  different time than the dummy until it migrates. Suspended accounts keep
  the bcrypt state "present" until they sign in again or are deleted.

## Sessions

- Idle 14 days (`PRIVATE_MESSENGER_SESSION_IDLE_DAYS`), absolute 30 days
  (`PRIVATE_MESSENGER_SESSION_ABSOLUTE_DAYS`), 1-365 days each, idle not above
  absolute. The absolute lifetime counts from the last password and
  device-secret check. Upgrading signs out sessions idle for more than
  14 days.
- `POST /api/v1/auth/reauth` with `X-Veritra-Rotate-Session: 1` returns
  `{"token": ...}`. One SQL statement makes the new token current and keeps
  the presented token for 2 minutes. During that time the old token cannot use
  recent authentication, cannot extend the session, and its sockets close when
  the 2 minutes end. Without the header the endpoint keeps its 204 behaviour,
  for older clients.
- A retry with the old token inside the 2 minutes (lost response) replaces
  the unreceived token without extending the grace. At any moment a session
  has one current token and at most one old token that expires within
  2 minutes. Concurrent rotations leave exactly one current token
  (`TestConcurrentRotationLeavesExactlyOneCurrentToken`).
- Revocation: sign-out with either token deletes the session. Password
  change and sign-out of other devices drop the old token and close the
  account's sockets. Device removal, account suspension and offline owner
  reset delete the session row.
- Rotation on every request was rejected: concurrent requests and lost
  responses would strand mobile clients. Rotation happens at each strong
  authentication instead.

## Rollback

Migration `0032_session_rotation.sql` is additive. An older binary starts on
the new database, ignores both columns and keeps accepting current tokens.
It cannot verify Argon2id hashes: every account that signed in, registered or
changed its password after the upgrade fails password sign-in on the old
binary. Existing sessions keep working until they expire. Operator options,
in order:

1. Roll forward: fix and redeploy the new binary.
2. Restore the backup taken before the upgrade. Data written since is lost.
3. Stay on the old binary with the current database. Then only the owner can
   be recovered, with that binary's `reset-owner-password` (which writes
   bcrypt), and other migrated users cannot sign in with a password.

## Advisor checkpoint

No Agent tool was available, so the review ran as the `code-review` skill
(forked, high effort) over the full diff.
Question: find enumeration or timing oracles, ways to keep two indefinitely
valid credentials, revocation gaps, concurrent-rotation races, rollback
hazards, semaphore DoS and secret logging.

Adopted:
- Anonymous sign-in floods could hold every hashing slot. One slot is now
  reserved for signed-in callers (reauth, password change, rehash after full
  sign-in). Existing sessions never hash. Anonymous sign-in under a flood
  still depends on the per-IP auth budget.
- The mobile client reported success when a rotated token arrived after the
  session changed. It now reports failure.
- Setting only the absolute lifetime below 14 days failed startup. The idle
  default now follows it.
- `docs/operations.md` and `server/config.example.env` still described bcrypt.
  Both are updated.
- A socket opened with the old token on the caller's own device survived
  password change and sign-out of other devices. Both now close it.
- Smaller fixes: a shared days parser, one idle/absolute clamp, and one Go
  legacy-hash predicate cross-referenced from the SQL.

Rejected:
- "A duplicated rotating request kills the received token." Neither the client
  nor standard proxies replay POSTs. The outcome is a fresh sign-in, so it
  fails safe. Refusing retries would strand the more likely lost-response
  case in the same way.
- "Sign-out with the old token ends the new one." This is intended: either
  token revokes the session.
- "Count only active accounts as legacy." Suspended accounts can be
  reactivated, and counting them keeps timing uniform without a hook.
- "The fallback lookup doubles reads for bad tokens." It uses an index, runs
  only on misses, and rate limits bound it.
- "In-flight tasks drop results after rotation." The client restarts sync
  and push registration with the new token.
- "Older parameters or another bcrypt cost differ in timing." Recorded above
  as residuals.

## Checks

- `go test -p 2 ./internal/auth ./internal/config ./internal/storage ./internal/httpapi`: pass, and again with `-race`.
- `go vet ./...` and `gofmt -l .`: clean. The repository has no golangci-lint config.
- `flutter analyze` and `dart format --set-exit-if-changed` on the touched files: clean.
  `flutter test test/app_state_test.dart test/api_contract_test.dart`: pass.
- `scripts/test-api-contracts.sh` (live server plus native library), including
  the rotation and grace assertions: pass.
