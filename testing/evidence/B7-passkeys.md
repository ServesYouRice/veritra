# B7 passkeys: evidence

Package B7, design `docs/designs/B7-passkeys.md`, owner defaults D93.

## S1 and S2: server (this change)

- Migration `0057_passkeys.sql` (tables only; an older binary ignores them).
- Go library `github.com/go-webauthn/webauthn` v0.18.2 (D89), with the
  transitive modules listed in `THIRD_PARTY_NOTICES.md`; licences checked in
  the module cache (BSD-3-Clause, MIT, Apache-2.0 for `go-tpm`).
- Tests in `server/internal/httpapi/passkey_test.go` use a software
  authenticator written in the test (ES256 and Ed25519, attestation `none`,
  Android app origin). They cover: register and sign in; wrong device
  secret, unknown device, revoked device and suspended account (same 401);
  wrong user handle; another account's credential and instance-unique
  credential IDs; replayed, expired and single-use ceremonies; two concurrent
  finishes (exactly one session); a passkey deleted and a device secret
  changed between verification and the writer transaction; backup
  eligibility change refused, backup state stored; sign-count regression
  refused and audited, synced passkeys (count 0) accepted; no `recent_auth_at`
  after a passkey sign-in and `recent_auth_required` on every
  `withRecentAuth` route; registration refused without recent auth; shared
  backoff with the password path and no lock-out by strangers; the 10-passkey
  limit, rename, delete, audit and sync events (row ID only); the
  4-ceremony cap and device-revoke cleanup; account deletion cleanup;
  well-known files, setup status and the off-by-default 404/503.
- `config` tests: startup refuses a port, an IP, `localhost`, `http` and a
  host without a dot; app lists are parsed and validated.
- `account_recovery_test.go`: K0 completion deletes passkeys, the handle and
  open ceremonies (S2, O5 default).
- Account export lists passkey name and times only.

## Not done yet

- S3 (Flutter app), S4 to S6 (account switcher), and the on-device runs
  (Windows Hello by the owner; Android and iOS need signed builds).
