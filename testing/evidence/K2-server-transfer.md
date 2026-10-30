# K2 server history transfer - 2026-10-28

Status: server resource implemented; independent coordinator review found no
blocking issue after checking the guard/intent/rename/finalize lifecycle,
authorization, immutable replay, quota accounting and terminal cleanup.
Windows checks below and independent Linux confirmation pass. K2 as a
whole is not complete: this evidence does not cover native/mobile transport,
history snapshot import, local durable import ledger, or device validation.

Contract and ownership:
[K2-transfer-resource.md](../../docs/designs/K2-transfer-resource.md).
New server files are `uploads/prepared.go`, storage/HTTP
`device_history_transfer_*`, HTTP capability test, and migration 0039.
Existing server files have narrow guard, routing, account/device cleanup,
retention, byte/blob quota, admin usage, chunk-record and backup-reference
integrations. No dependency, Flutter, Rust, release gate or STATE change.

The original source uploads one immutable ciphertext/handoff; the exact
recipient session or link claim credential reads metadata/ranges and ACKs.
GET never consumes the resource. ACK atomically erases handoff/blob refs,
queues deletion and retains an idempotent receipt. Cancellation affects the
copy only. Every operation checks active account/devices and the fixed
seven-day approval deadline.

Prepared local writes install an active guard before durable SQL intent and
quota registration, create files only afterward, and retain the guard through
final metadata commit. Deletion returns retryable busy while guarded, even
after late rename. Expiry/revocation/cancellation enqueue before erasing
intents/refs. Ambiguous finalization errors retain durable reconciliation
state instead of directly deleting a potentially committed blob. Unsupported
prepared-write backends return 503. Upload context/body-close budget is five
minutes; intent lease is at most ten minutes and never beyond transfer expiry.

Executed from `server` on Windows:

```text
go test -p 1 ./internal/uploads ./internal/storage ./internal/httpapi -run 'TestPrepared|TestHistoryTransfer' -count=1
PASS (uploads0.488s/storage3.626s/HTTP3.444s)

go test -p 1 ./internal/uploads ./internal/storage ./internal/httpapi -count=1
PASS (uploads0.619s/storage31.949s/HTTP21.916s)

go test -p 1 ./internal/storage -run 'TestHistoryTransferActualProcessExitAfterRenameBeforeSQL|TestHistoryTransferMigrationFailureRollsBackAndPreservesExistingData' -count=1
PASS (1.414s; these final two tests were added after the full run)

go vet ./internal/uploads ./internal/storage ./internal/httpapi ./internal/app
PASS

git diff --check
PASS (line-ending warnings only)
```

Principal tests:

- `TestPreparedWriteGuardPrecedesRegistrationAndSurvivesRename`,
  `TestPreparedRegistrationFailureCreatesNoFileAndReleasesGuard`,
  `TestPreparedTemporaryCleanupSkipsGuardedFile`.
- `TestHistoryTransferInvalidationDuringWriteNeverAcknowledgesEarlyDeletion`:
  blocked reader, intent expiry/source revoke/recipient revoke/copy cancel,
  durable deletion queue, busy early delete, late rename, rejected finalize,
  then safe deletion after guard release.
- `TestHistoryTransferActualProcessExitAfterRenameBeforeSQL`: child process
  exits without deferred cleanup after fsynced rename; replacement process
  state retains the SQL intent, expiry queues the final blob, cleanup and a
  fresh upload succeed. A separate simulated-restart test also passes.
- `TestHistoryTransferImmutableRetryAuthorizationAndAck`: exact response-loss
  retry, changed handoff conflict, source/recipient/claim guards, no source
  content/handoff, no quota double charge, queue failure rolls ACK back,
  repeated durable ACK, erased secret refs and released quota.
- `TestHistoryTransferFinalizeRollbackAndBackupReferences`: injected metadata
  insert failure retains quota-charged intent and blob without unsafe queue;
  retry succeeds and server backup inventory includes active transfer.
- `TestHistoryTransferCommittedLifecycleQueuesCiphertextAndReleasesQuota`:
  expiry/source revoke/recipient revoke/account deletion/copy cancellation.
- `TestHistoryTransferMigrationFailureRollsBackAndPreservesExistingData`:
  injected late 0039 failure leaves no partial tables/triggers/column/version;
  retry upgrades and retains existing account data.
- `TestHistoryTransferHTTPUploadRangeRetryAndDurableAck`: multipart upload,
  identical retry, read-only metadata, scoped sessions/claim credentials,
  repeated verified ranges/ETag, 416, no malformed-session fallback, ACK.
- `TestHistoryTransferHTTPRejectsMalformedOrReplacedUpload`: extra part,
  digest/size/transcript mismatch, handoff/ciphertext cap, unknown metadata,
  wrong uploader; no active row is committed.
- `TestHistoryTransferUnsupportedBlobBackendFailsClosed`.

The new HTTP contract helper uses distinct test addresses to keep the
transport contract independent of the existing credential-address limiter.
Production rate policy and existing fixtures are unchanged.

Independent Linux confirmation (frozen migration0039 slice, before D52/0040):

```text
go test -p 1 ./... -count=1
PASS (all Go packages)
go test -race -p 1 ./internal/uploads ./internal/storage ./internal/httpapi -run 'TestPrepared|TestHistoryTransfer|TestDeviceLinkV3LostCompletionResponseAndConcurrentRetry' -count=1
PASS (uploads1.044s/storage29.547s/httpapi16.660s)
gofmt -l .
PASS (no output)
go vet ./...
PASS
```

The coordinator used the pinned Go 1.26.10 Linux toolchain with two CPUs and
serial package compilation. Local logs: `build/transfer-verification-results/`.
No blocking review finding remains in this server slice. This is not the
human independent crypto review or an end-to-end K2 device-transfer check.

The server accepts an authenticated ACK assertion; it cannot prove the
recipient's local import transaction committed. The client must enforce that
ordering before using this route. The process-crash check exercises the
blob/SQL boundary directly; the pre-existing server process lock remains the
deployment condition excluding simultaneous writer processes.
