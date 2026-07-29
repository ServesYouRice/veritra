# Release evidence matrix

Candidate commit: **2c5c506be274aba5239eb125428cdc510b292696**

Independent reviewer: **not assigned**

## Automated evidence

| Evidence | Result | Artifact / notes |
|---|---|---|
| Go tests | Pass | `go test ./...` in pinned Go 1.25 container |
| Rust tests and vectors | Pass | 17 tests with pinned Rust 1.90 |
| Flutter analyze/non-UI tests | Pass | Analyzer clean; 24 pass, 2 environment skips |
| UI-only Flutter tests | Excluded/blocking | Excluded by request; not release evidence |
| Contract/integration tests | Pending | Live server/native library not configured locally |
| Direct license notices | Pass | Full transitive scan remains required |
| Android debug build | Pass | `app-debug.apk`; unsigned and not release evidence |
| Android reproducible release build | Pending | Unsigned until approval |
| iOS reproducible release build | External | Requires macOS/signing |
| SPDX SBOM/checksums/provenance | External | Gated release workflow |
| Release-readiness gate | Expected fail, verified | `PM_CRYPTO_UNAVAILABLE` remains wired |

## Real-device evidence

UI-only accessibility work is excluded from this implementation request, but
it remains a release requirement and cannot be waived.

| Flow | Android | iOS |
|---|---|---|
| Setup, invite, DM/group | Pending hardware | Pending hardware |
| Device link and SAS comparison | Pending hardware | Pending hardware |
| Offline catch-up and restart | Pending hardware | Pending hardware |
| Attachment and backup recovery | Pending hardware | Pending hardware |
| Revocation reconnect orderings | Pending hardware | Pending hardware |
| FCM/APNs background wake | Pending credentials/hardware | Pending credentials/hardware |
| TURN call under network changes | Pending TURN/hardware | Pending TURN/hardware |
| TalkBack/VoiceOver/large text | Excluded here; release blocker | Excluded here; release blocker |

## Findings

Record finding ID, severity, affected commit/file, remediation commit, reviewer
retest, and residual-risk decision here. No findings have yet been supplied by
an independent reviewer.
