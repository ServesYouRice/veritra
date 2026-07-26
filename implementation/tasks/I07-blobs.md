# I07 — Make encrypted blobs durable

Goal: committed blob rows always map to durable, authorized ciphertext files.

Read:

- blob/upload storage and handlers under `server/internal/`
- backup/restore code and tests
- request-timeout configuration

Do:

1. Test sync/rename failures, truncated files, failed post-commit deletion, and interrupted downloads.
2. Sync file and parent directory before committing metadata.
3. Validate safe size/integrity metadata when opening a blob.
4. Add durable orphan-deletion reconciliation.
5. Support safe large downloads and resume/range behavior without bypassing authorization.

Done when: failure injection leaves recoverable state and large encrypted downloads are not killed by the default request timeout.

Verify:

```powershell
Push-Location server; go test ./internal/storage ./internal/httpapi; Pop-Location
```

Never log keys, blob bytes, or content-derived data.
