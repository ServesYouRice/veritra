# L3: confidential-cloud mode

**Status: proposed (2026-11-07), not built.** A design only, against `main`
(crypto ABI 13, server migration 0049, local schema 20). It touches
artifact trust and release-gate wording, so it needs an independent review
(AGENTS.md) and the owner's answers at the end before it is built. The
release gates G24 and G25 do not change.

## Summary

- **What it is.** An operator can run the Veritra server inside a
  confidential VM (AMD SEV-SNP or Intel TDX). The hardware signs a report
  saying what booted (firmware, kernel, initrd). Veritra exposes that
  report, tied to the server's TLS key, so anyone can compare it with an
  expected measurement built from the reproducible release (L2-4).
- **What it buys.** Metadata only. Message bodies and attachments are
  already end-to-end encrypted, so a confidential VM adds nothing to their
  secrecy. It raises the cost for a host provider or an intruder to read
  the server's memory and database: who talks to whom, when, device lists.
- **What it never claims.** It is **not operator-proof.** The operator
  chooses the image, the network, the proxy in front, the disk, and can
  switch the mode off. Hardware vendors and their firmware are trusted.
  Side channels exist. No doc, UI string or release note may say or imply
  "operator-proof", "the operator cannot see" or "zero access".
- **Two steps.** L3-1 builds a proof hook, switched off, with no vendor
  dependency. L3-2 documents one optional setup.

## Where things stand

- The server runs as one replica, non-root, read-only root, on a single
  OVH VPS under k3s (STATE.md, Deployment). Nothing measures or attests it.
- Releases carry an SBOM and GitHub provenance (`release.yml`); the image is
  built `-trimpath -buildvcs=false -buildid=` into `scratch`. L2-4 adds the
  rebuild-and-compare script; until then the digest is attested but not
  independently reproduced.
- Storage, crypto, push, uploads, realtime and calls are behind interfaces
  (AGENTS.md); there is no attestation interface.
- Clients trust the server for nothing confidential (`docs/sdk.md` §6), so
  no client trust decision depends on how the server is hosted.

## Threats

| Adversary | Without L3 | With L3-2 set up | Left |
|---|---|---|---|
| Host provider staff read VM memory or disk | Metadata readable | Memory encrypted by the CPU; disk sealed to the measured VM | Firmware or CPU bugs, side channels, a provider that *is* the attester |
| Intruder with root on the host (not in the VM) | Metadata readable | As above | Same |
| Operator swaps in a modified image | Undetectable from outside | The report shows a measurement that differs from the expected one | Anyone must actually check. The operator can also simply turn L3 off |
| Operator logs at the proxy (Caddy, Traefik) | Addresses logged (L2-2 removes by default) | Unchanged: the proxy is outside the VM unless the setup puts it inside | The network path; DNS; the provider's flow logs |
| Operator relays `/attestation` to a real confidential VM and serves traffic from an ordinary box | n/a | Fails: the report is bound to the TLS key of the connection | An operator who gets the TLS key into both machines; TLS must stay inside the VM |
| Operator, generally | Full control | Full control | **This is why L3 is not operator-proof** |
| Content of messages | Already E2EE | Already E2EE | — |
| A client treats "attested" as "trusted" | n/a | Must not happen: see "No client trust gate" | — |

### No client trust gate

The app never relaxes anything because a server is attested. Attestation is
shown, if at all, as an operator-provided fact on a settings info page, with
the text "This server says it runs in a confidential VM. That does not stop
the operator from seeing metadata." It never changes MLS checks, L1 pins,
padding, sealed-sender use, retention, or any warning.

## Steps

Numbers are the next free ones when each step lands; nothing reserves one.

### L3-1 Proof hook, switched off (Opus review)

- A Go interface in `server/internal/attest`:

  ```go
  type Provider interface {
      Kind() string                              // "none", "sev-snp", "tdx"
      Report(ctx context.Context, nonce [32]byte) (Evidence, error)
  }
  ```

  The only built-in implementation is `none`, which returns
  `ErrNotConfigured`. Real providers read the kernel's `configfs-tsm`
  report interface (Linux 6.7+), which needs no vendor SDK, or come as a
  separate optional build tag; either way **no new Go module** in L3-1.
- `GET /api/v1/attestation?nonce=<hex32>`: 404 unless
  `PRIVATE_MESSENGER_ATTESTATION=configfs-tsm` (default unset). Unauthenticated,
  rate-limited like other public routes. The report's 64-byte user-data
  field holds `SHA-512("veritra-attest-v1" || nonce || SHA-256(server TLS
  public key))`, so a report relayed from some other machine fails: the
  verifier checks that key against the certificate it actually connected
  to. TLS must therefore terminate inside the VM. The response also lists
  `main.version`, `main.commit` and the image digest, labelled
  `claimed_build`: they are the server's own claim, not evidence.
- Logged as a route pattern only; no nonce, no report body in logs.
- `docs/operations.md`: one paragraph saying what the switch does and the
  "not operator-proof" text.
- **Counters: none** (no ABI, no migration, no schema).

### L3-2 Optional documented setup (Sonnet, owner first for the host)

- `docs/operations.md` section "Confidential VM (optional)" with one tested
  recipe: a provider that sells SEV-SNP or TDX VMs, and a published VM image
  (a unified kernel image whose measured initrd contains the reproducible
  server binary from L2-4), so the hardware measurement covers the server
  itself; a container pulled after boot would not be measured, the data volume encrypted with a
  key released only to the measured VM, TLS terminating inside the VM
  (so the proxy, if any, sees only ciphertext).
- `scripts/verify-attestation.sh <url>`: fetches a report with a fresh
  nonce, checks the vendor signature chain and the user-data binding to the
  TLS key it connected to, and compares the launch measurement with the
  expected value recomputed from the published VM image. Prints "matches release X" or
  "does not match"; never "secure" or "trusted".
- Every new string is checked against the banned phrases above (lint for
  app strings, review for docs).
- **Counters: none.** A verifier library, if the script needs one beyond
  `openssl`, is a new dependency: owner first.

## Test plan

- **L3-1:** Go tests: route is 404 with the switch unset; `none` provider
  never returns evidence; a fake provider receives the user-data hash of
  the nonce and TLS key, and its report is returned byte for byte; a bad nonce is 400; logs contain neither nonce nor
  report. Grep test: the mobile app has no code path that reads the route
  to make a trust decision.
- **L3-2:** run the recipe once on a real confidential VM and record
  the report and verifier output in `testing/evidence/` (needs the
  owner's host). A deliberately changed image produces "does not match",
  and a report fetched through a relay to a second machine fails the TLS
  binding.
- **Wording lint:** `scripts/lint` fails if a new L3 app string (keys
  prefixed `attestation`) in `mobile/lib/l10n/` contains "operator-proof",
  "zero access" or "cannot see". Docs keep the phrase only in the negated form ("not
  operator-proof"), checked by review.
- `scripts/test`, `scripts/lint`; `scripts/release-readiness.sh` fails for
  the same reasons as before.

## Open questions for the owner

1. **Host.** The current plan is an OVH VPS, which (confidence 70%) does not
   offer SEV-SNP or TDX. **Default: build L3-1 only now; write L3-2 against
   a provider you pick later**, and keep OVH for production.
2. **Show it in the app?** **Default: no app UI**; the verify script is for
   people who check. If shown later, only the info-page text above.
3. **Provider support.** **Default: Linux `configfs-tsm` only**, no vendor
   SDK, so SEV-SNP and TDX work through the same kernel interface.
4. **Verifier dependency** for `verify-attestation.sh`. **Default: none**
   (shell plus `openssl`); a library only if that proves impossible.
