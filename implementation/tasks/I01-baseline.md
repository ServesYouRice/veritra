# I01 — Establish a clean baseline

Goal: record the real current failures before feature work.

Read:

- `scripts/test.ps1`, `scripts/lint.ps1`, `scripts/release-readiness.sh`
- `server/websetup/index.html`, `server/websetup/websetup_test.go`
- `mobile/lib/features/auth/qr_scan_screen.dart`

Do:

1. Run the focused setup test and Flutter analyze/test.
2. Fix only a confirmed setup-notice or scanner API failure.
3. Run the aggregate test and lint scripts.
4. Run release readiness. Its crypto failure is expected until I25; any other failure is a blocker.
5. Move newly unblocked cards to Ready.

Done when: tests and lint pass, and release readiness fails only at the intentional crypto gate.

Verify:

```powershell
Push-Location server; go test ./websetup; Pop-Location
Push-Location mobile; flutter analyze; flutter test; Pop-Location
.\scripts\test.ps1
.\scripts\lint.ps1
bash ./scripts/release-readiness.sh
```

Do not weaken tests or the crypto gate. Record unavailable toolchains as a blocker.
