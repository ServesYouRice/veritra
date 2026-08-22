# T43B — Actionable first-run connection flow

| Field | Contract |
|---|---|
| Consensus source | I43 onboarding scope; UI-08/NTH-02; U2/U3/U4/R15 |
| Initial eligibility | Ready |
| Risk | High pre-release usability blocker |
| Executor | Balanced+advisor |
| Advisor | Review state discovery, TLS errors and deep-link trust boundaries |
| Depends on | — |
| Blocks | T43C/G24 onboarding evidence |
| Parallel safety | Coordinate connect/API client edits with T44A/T44C |

## Objective

Start with an empty HTTPS origin, discover valid server/auth state, and make
offline, DNS, TLS and not-Veritra failures explicit and recoverable.

## Read first

- `docs/audit-consensus.md` I43.
- Named onboarding findings.
- `mobile/lib/features/auth/connect_screen.dart`, QR screen, API client/models,
  `app_state.dart`, Android/iOS network config and auth UI tests.

## Invariants

- Never default a physical device to a phone-local address that cannot work.
- TLS failures are not silently bypassed; QR/deep links do not auto-trust an origin.
- Setup versus sign-in follows probed server/device state.

## Work

1. Model connection probe and typed failure states.
2. Remove misleading default origin and auth-mode default.
3. Add state-driven setup/sign-in selection and actionable errors.
4. Add safe QR/deep-link prefill with explicit origin confirmation.
5. Test fresh server, linked device, offline, DNS/TLS and wrong-server cases.

## Acceptance

- Every first-run state provides the correct next action.
- No insecure trust bypass or hidden probe failure.
- 320 px/keyboard/large-text flow remains usable.

## Required checks

```sh
cd mobile && flutter test test/ui_actionable_test.dart test/ui_features_test.dart test/app_state_test.dart
```

