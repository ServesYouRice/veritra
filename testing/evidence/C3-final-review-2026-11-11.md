# C3 final review, 2026-11-11

Reviewed `e9aee56d5f0999bde775512dc40ccd52a2b10be6..f8b66ab` on
`ai/c3-rest`, `.ai-report.md`, the C3 design, and `origin/agent/c3`.
An independent review agent checked security and reviewed the fixes.

## Fixes

- Snapshot-based community/channel edits now require the displayed revision
  on every upload attempt. A conflicting unseen record fails the save instead
  of overwriting its preserved fields. Accepted cache loading preserves token
  refresh behavior.
- A rotation keeps its durable pending mark if its new record's announcement
  was not queued. The next pass retries under the same rotation key.
- Announcement healing requires matching key ID and an own/authorized sender;
  an ordinary member cannot suppress a failed community announcement.
- Four new regressions cover rotation retry, version conflicts both before
  upload and during retry, unauthorized announcements, and app-level guarding.

## Remaining blockers

- **High: retired key replay after pruning.** `currentKey()` reconstructs
  first-seen order from retained key rows only. After pruning K0, a trusted
  stale admin's redelivery gives K0 a new sequence and makes it current again.
  Subsequent edits can use a key retained by removed members. A hostile server
  can deliver MLS commits while withholding newer info messages from that
  admin. Durable authenticated generation/provenance across pruning is needed;
  this review does not introduce a new key protocol or schema.
- Production `verifiedCommunityRoles()` still has no verified role source;
  peer acceptance and editors remain closed. The restriction flag is absent.
- Only local removals mark rotations; remote/moderator removals do not trigger
  an admin rotation. Immediate delivery after add commits is also missing.
- Conversion, category/icon screens, plaintext-name refusal and column removal
  remain missing. Creation still transmits names in plaintext. C3 is partial.

The replay was confirmed by a temporary native-backed Flutter probe: create
K0, create five more keys, assert K0 was evicted, record K0 again, then assert
`currentKey != K0`. The last assertion failed. The probe was removed after
execution; its failure output is retained in `c3-final-review-key-replay.log`.
The existing short replay test never crosses pruning and misses this case.

## Checks

- `go test ./internal/storage ./internal/domain`: pass; `go vet ./...`: pass.
- `cargo test`: 230 passed, 8 existing ignores; clippy all targets with
  warnings denied: pass.
- Focused seven C3 Flutter files: 81 passed, no skips, native library enabled.
- `scripts/test.ps1`: pass, including policy fixtures, all Go/Rust tests and
  Flutter (2,442 passed, 21 existing skips).
- `scripts/lint.ps1`: pass (Go vet, Rust fmt/clippy, Flutter analyze/format).
- `git diff --check`: pass.
- A redundant simultaneous Flutter invocation hit a Windows native-asset DLL
  lock; the full scripted run completed successfully. No product change was
  made for that tooling collision.

Reserved local schema 35 and server migration 0067 remain unused. This diff
adds no schema, ABI, dependency, or release-gate changes. Local schema remains
32, latest server migration 0066. Release uses `UnavailableCryptoService`.
