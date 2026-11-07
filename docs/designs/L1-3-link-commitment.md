# L1-3: commit-then-reveal for device linking (TASK-010, TASK-048)

Owner decision D100 (A): build the key commitment for device linking
together with L1. This closes the residual case that
[L0](L0-device-link-v2.md) left open: someone who saw the QR code (the
128-bit link secret) and also controls the relay.

## The gap this closes

Under L0 the SAS, claim tag and approval tag are MACs keyed from the QR
secret. Without the secret a relay can evaluate none of them. With it, the
relay can forge both tags, so the 8-digit SAS (about 26.6 bits) is the only
check left. The audit assumed key grinding at about 10^4 key generations per
side. The real cost is lower. The old device builds its transcript from the
link nonce the server returns when the device refreshes, so the relay can
grind that nonce with HMAC evaluations alone, after it has seen the new
device's key. A test on the old code matched 4 of the 8 digits after 3,645
tries (0.5 s, debug build). All 8 digits take about 10^8 HMACs, which is
minutes.

## Protocol `veritra-device-link-v4` (K2 route, `/api/v1/device-links/v3`)

The construction is SAS-MCA (Vaudenay, CRYPTO 2005), shaped like the hash
commitment in ZRTP (RFC 6189). One side commits, and both sides contribute a
fresh random.

| Step | Existing device (source, S) | Server | New device (N) |
|---|---|---|---|
| 1 create | draws `r_S` (32 bytes), computes `C = commit(r_S)` and posts `C` with the locator | stores `C` (write-once) | |
| 2 reserve | | returns `C` with the nonce and the source key | refuses a reservation without `C` or with an all-zero `C` |
| 3 claim | | stores `r_N` (write-once) | native draws `r_N`; claim transcript includes `C` and `r_N`; posts claim tag and `r_N` |
| 4 accept | GET claim; native checks the claim tag and that `r_S` opens `C`, then stores the record (one claim per link) | | |
| 5 reveal | only after step 4 is committed: `POST .../reveal {r_S}` | stores `r_S` once (source only, claimed state) | |
| 6 show | | claim-status carries `r_S` | native opens `C` with `r_S` (read only) and shows the SAS; a mismatch ends the claim with its own message |
| 7 approve | the user types N's code; native compares; approval tag | refuses approval before step 5 (`409 reveal_required`) | refuses an approved record without a reveal; checks the approval tag, which binds `C` through the transcript (the native opening is not repeated here, because it needs the link window and a late approval must still finish) |

- `commit(r_S) = SHA-256(lp("veritra-device-link-commitment"), lp(version),
  lp(origin), lp(account), lp(source device id), lp(source signing key),
  lp(r_S))`, where `lp` is a u16-BE length prefix. The link ID does not exist
  yet when S commits, so the transcript binds it instead. Replaying an old
  commitment whose opening the relay knows gains nothing: S's SAS still
  depends on S's own fresh `r_S`, which stays hidden until S has accepted a
  claim, and S opens only its own commitment.
- The claim transcript is v3's, with the new version string, plus `C` and
  `r_N`: domain, version, origin, link ID, account, nonce, source ID and key,
  recipient ID and key, transfer key, `C`, `r_N`. The transcript hash, claim
  tag (`veritra-link-claim-v4`) and approval tag
  (`veritra-link-approval-v4`) cover it.
- `SAS = HMAC(K_sas, transcript || lp(r_S))`, first 4 bytes as a big-endian
  integer mod 10^8, 8 digits. `K_sas = HKDF-Expand(PRK(secret),
  "veritra-link-sas-v4")`. The handoff key label is `veritra-link-handoff-v4`.
- The approval tag does not cover `r_S`. N checks the approval on a scratch
  copy of its frozen pending state and again after promotion. Neither copy
  ever holds `r_S`, because the reveal arrives after the state froze. The
  approval still binds `r_S` through `C`, which is in the transcript.

**Why one guess.** The relay must give N a commitment before N picks `r_N`,
and it must give S a claim before S reveals `r_S`. S accepts one claim per
link, so whatever it tells S is fixed before `r_S` is known. Whatever it
tells N is fixed, by the commitment, before `r_N` is known. Each SAS
therefore depends on a fresh random that the relay had to commit to before
seeing it. The two values match with probability about 10^-8 per run, and
each run is a user action. The secret-keyed MACs still protect a relay that
lacks the secret. Vector: `testing/vectors/device-link-v4.json`, computed
by `device-link-v4.py` (standard library only) and checked by Rust.

**SAS length.** Kept at 8 digits. With commit-then-reveal the bound is
`10^-8` per attempt, which the D100 brief accepts. A longer code costs
usability and adds no structural protection. This is a product choice the
owner already made (D100 A); revisit it only if attempts can be automated
without the user.

## Downgrade

- Clients speak v4 only. The Dart models refuse any other `protocol_version`
  and a reservation or record without a nonzero commitment. Native `derive`
  hard-codes the v4 transcript. Nothing falls back to v3 or v2.
- ABI 18 removes `pm_crypto_device_link_transcript_hash`, the v2
  derivation, so no client built on ABI 18 can compute a v2 SAS.
- The server accepts only v4 on the K2 routes. Migration 0060 revokes
  pending and claimed links that have no commitment. Approved v3 links keep
  their device and window. Their history copy ends, because clients drop
  native v3 transfer records (below).
- **Open (follow-up):** the server's legacy v2 routes (`POST
  /api/v1/device-links`, claim-enrollment, claim, approve, claim-status)
  still exist, and five Go HTTP tests build v2 links inline, including
  L1's `device_list_test`. No client speaks v2 after ABI 18. Deleting the
  routes, their store code and those tests is a separate cleanup that should
  land after L1. Until then the routes are dead but reachable.

## Rate limits

A link now costs two extra requests: the source's reveal and the new
device's poll that reads it. All nested v3 paths used to share the
credential budget (10 a minute per address), and both of a user's devices
usually share one address. The source's reveal and approve check only a
session token, never a claim token, password or code, like the v2
approval. Their exact clean spellings
(`/device-links/v3/<id>/reveal|approve`) now take the signed-in budget;
every other spelling and every claim-token route stays credential
(`route_class.go`). This keeps a link at the old count of six credential
requests, and the demo e2e passes again. Pre-existing and still open: the
new device polls claim-status every 4 s (15 a minute) against that
10-a-minute budget. That is for the owner or ops to decide.

## Storage

- Server migration 0060: `device_links_v3.source_commitment`,
  `recipient_random`, `source_random` (each 32 bytes, write-once) and
  `revealed_at`. Replays must repeat the same values: create compares `C`,
  claim compares `r_N` (the signed proof does not cover it), and reveal
  compares `r_S`. The K2 history transfer keeps its own label,
  `veritra-device-link-v3`, because it binds the link through the transcript
  hash.
- Native transfer record item version 2 adds `C`, `r_N`, `K_sas` and, on
  the source only, `r_S` plus the 4 SAS bytes. Version-1 records (protocol
  v3) are dropped on load, never refused. A refusal would make the whole
  sealed state unreadable. Tests cover both genuine format-3 fixtures,
  through `state.rs` and through `records.rs`.
- S keeps `r_S` in memory with the link secret; both are wiped together. N
  never stores its SAS: after a restart it derives it again from the reveal,
  read only, so the frozen pending state needs no change and no local schema
  bump.

## ABI 18

Context gains F32 commitment and F32 recipient random. `receive_begin`
returns key, `r_N`, hash and tag, and no SAS. `source_accept` takes `r_S`.
`inspect` reports `has_sas`. Two new ops: 12 `reveal_sas` (read only) and
13 `source_commitment` (pure, under this device's own identity). See
[K2 ABI](K2-abi8-boundary.md).
