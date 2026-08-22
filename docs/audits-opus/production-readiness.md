# Production readiness

Build and release integrity, CI gates, deployment, platform configuration, and
testing gaps. This file covers what would otherwise be three thinner ones
(`deployment-risks.md`, `testing-gaps.md`, `architecture-review.md`) — the
findings interlock too much to separate usefully.

**Baseline.** This project's release engineering is already better than most.
Every GitHub Action is pinned by commit SHA. Toolchains are pinned
(`rust-toolchain.toml`, explicit Go and Flutter versions). Migrations are
checksummed and refuse to run against a modified file. The container is
`FROM scratch`, non-root, with `no-new-privileges`, memory and PID limits. There
is an SPDX SBOM, checksums, and build provenance attestation. Licences are
verified across 157 Dart packages and the full Go and Rust graphs. A single-writer
lock prevents a second process from corrupting the data directory. A restore
drill is documented and was actually run.

The findings below are gaps in that structure, not an absence of it.

| ID | Severity | Title | Area | Blocker |
| --- | --- | --- | --- | --- |
| [R1](#r1) | **High** | Container ships a Go toolchain CI never tests | Release integrity | **Yes** |
| [R2](#r2) | **High** | The release gate is two greps and is trivially bypassed | Release integrity | **Yes** |
| [R3](#r3) | **High** | No vulnerability scanning in CI; the I27 exception has no tripwire | Supply chain | **Yes** |
| [R13](#r13) | **High** | iOS lacks the background modes and CallKit path calls require | Platform config | **Yes**¹ |
| [R14](#r14) | **High** | Android lacks the foreground-service type calls require | Platform config | **Yes**¹ |
| [R4](#r4) | Medium | Shutdown grace, drain deadline and upload timeout contradict each other | Deployment | No |
| [R5](#r5) | Medium | No down migrations; any rollback across one is a full restore | Deployment | No |
| [R6](#r6) | Medium | No golden tests, and the visual rebuild was never rendered | Testing | No |
| [R8](#r8) | Medium | No automated backup in any shipped deployment | Deployment | No |
| [R10](#r10) | Medium | The product has two names throughout | Release quality | No |
| [R15](#r15) | Medium | iOS cannot reach a LAN server (`NSLocalNetworkUsageDescription`) | Platform config | No |
| [R7](#r7) | Low | Coverage is measured and then discarded | Testing | No |
| [R9](#r9) | Low | Compose service lacks `cap_drop` and `read_only` | Deployment | No |
| [R11](#r11) | Low | `pubspec.yaml` identity is stale | Release quality | No |
| [R12](#r12) | Low | No export-compliance key; every upload will prompt | Release process | No |
| [R16](#r16) | Low | Stray empty directory beside the repository | Housekeeping | No |

¹ Blocking for the **calls** feature (in release scope per decision **D03**) and
for completing card **I24**, not for a build without calls.

---

## R1

### Container ships a Go toolchain CI never tests

**Severity:** High
**Location:** [`server/Dockerfile:1`](../../server/Dockerfile#L1) vs [`.github/workflows/ci.yml:22`](../../.github/workflows/ci.yml#L22) and [`.github/workflows/release.yml:25`](../../.github/workflows/release.yml#L25)

**Problem**

Three places pin a Go version, and they do not agree:

| Where | Version | Produces |
| --- | --- | --- |
| `server/go.mod` | `go 1.25.12` | language/stdlib floor |
| `.github/workflows/ci.yml` | `1.25.12` | every test, `go vet`, race detector |
| `.github/workflows/release.yml` | `1.25.12` | `messenger-server-linux-{amd64,arm64}` binaries |
| `server/Dockerfile` | `golang:1.26.4` (digest-pinned) | `ghcr.io/servesyourice/veritra` |

The container image — which `docs/overview.md:196` lists as a supported hosting
option, and which the Compose deployment builds — is compiled with a **major Go
version that no test has ever run against**.

This is recent and traceable: commit `d3026de` ("Bump golang from 1.25.12 to
1.26.4 in /server") is a Dependabot Docker update that moved the Dockerfile
without moving CI. Dependabot did exactly what it was configured to do; nothing
was watching for the resulting divergence.

It also invalidates a specific recorded piece of release evidence.
`docs/board.md:206` states: *"`govulncheck` initially found three reachable Go
standard-library issues; pinning Go 1.25.12 cleared them."* That result is bound
to 1.25.12. The container is not built with 1.25.12, so the evidence does not
cover the artefact most operators will actually run.

**Why it matters in production**

Two artefacts are published per release and they are not the same program. The
tarball binaries are tested, scanned and attested. The container is built from
the same source with a different compiler and standard library, and is covered by
none of that. Go minor releases change `crypto/tls` defaults, `net/http` parsing
behaviour, GC tuning and stdlib internals — the areas that matter most for a
server whose security posture depends on them.

The provenance attestation makes this sharper rather than softer: attesting an
artefact asserts a chain of custody, and asserting it over an untested build
configuration is worse than not asserting it.

**Fix**

1. **Single source of truth for the Go version.** Put it in one place — a
   `.go-version` file, or read `toolchain` from `go.mod` — and consume it from
   `ci.yml`, `release.yml` and the `Dockerfile` (`ARG GO_VERSION`). Dependabot
   then cannot move one without the others.
2. **Decide the version deliberately.** Either stay on 1.25.12 everywhere until
   1.26 has been tested and `govulncheck`-cleared, or move everything to 1.26.4
   and re-record the evidence. Do not leave them split.
3. **Add a CI assertion** that fails if the version in the Dockerfile does not
   match the one CI installs. Three lines of shell, and it makes the invariant
   permanent.
4. **Build and test the container in CI.** The `compose-smoke` job already builds
   it (`ci.yml:133`) — extend that job to run `go version` inside the image and
   compare it against the expected pin.
5. **Re-record the evidence.** Add a Go-version column to the board's release
   evidence matrix so every row states which toolchain produced it.
6. **Configure Dependabot** to group Go toolchain updates (Docker + actions +
   `go.mod`) into one PR, so this class of divergence cannot recur.

**Blocker:** **Yes.** Two different programs are published under one release
identity, and the vulnerability evidence covers only one of them.

**Related risks** — check the same question for Flutter (CI pins 3.44.0; is
anything else pinned separately?) and Rust (`rust-toolchain.toml` says 1.90.0 and
CI installs 1.90.0 — these agree, which is the model to copy).

---

## R2

### The release gate is two greps and is trivially bypassed

**Severity:** High
**Location:** [`scripts/release-readiness.sh`](../../scripts/release-readiness.sh)

**Problem**

The entire production gate is:

```sh
if grep -q 'PM_CRYPTO_UNAVAILABLE' crypto/rust/src/lib.rs || \
   grep -q 'UnavailableCryptoService' mobile/lib/main.dart; then
  echo "release blocked: production MLS crypto is not wired" >&2
  exit 1
fi
echo "release readiness gates passed"
```

Two negative greps against two hardcoded file paths. It fails **open** in every
direction:

- Rename `UnavailableCryptoService`, or move the wiring from `main.dart` into any
  other file, and the gate passes with the crypto still unwired.
- Move the `PM_CRYPTO_UNAVAILABLE` constant into `ffi.rs` or a `constants.rs` and
  the same happens.
- Conversely, a **comment** mentioning either string blocks a legitimate release —
  so the natural response to a false block is to delete the mention, which
  weakens the gate further.

It also does not check anything else the board says must be true before
production. From `docs/board.md`, the release requires: signed Android and iOS
builds, an assigned independent reviewer with all critical/high findings fixed and
retested, resolution of the I27 advisory exceptions, and a clean release matrix.
The gate verifies none of it — a tag push with every one of those outstanding
produces binaries, an SBOM, checksums and a provenance attestation.

**Why it matters in production**

This is the single control standing between a `git tag v1.0.0` and published,
attested artefacts. Its job is to be the thing that cannot be gotten around by
accident, and it is currently the thing most easily gotten around by accident —
because the most likely way to break it is an ordinary refactor that renames a
class, which produces no error anywhere.

Every other gate in this repository is stronger than this one: migrations are
checksummed, actions are SHA-pinned, licences are enumerated, `go vet` and
`clippy -D warnings` are enforced. The release gate is the weakest link and it
guards the most.

**Fix**

Invert it from "no forbidden string is present" to "every required condition is
proven".

1. **Assert positively.** Require an explicit marker that only a deliberate act
   can produce — e.g. a `crypto/PRODUCTION_CRYPTO.md` file recording the reviewed
   commit, the reviewer, and the date, whose absence blocks the release. A
   rename cannot forge it.
2. **Run the real check.** Execute a test that performs an end-to-end MLS
   round-trip through the production wiring and fails if it returns
   `PM_CRYPTO_UNAVAILABLE`. `ffi_group_lifecycle_exchanges_and_revokes_messages`
   already exists as a Rust test; the missing piece is asserting the **Dart
   wiring** actually reaches it. That is behaviour, not text.
3. **Extend the gate to the other release conditions:**
   - `scripts/audit-rust.sh` exits non-zero (see [R3](#r3));
   - `govulncheck ./...` is clean;
   - the board's release-evidence matrix contains no `Pending` in a blocking row —
     parseable, since the matrix is a Markdown table;
   - an independent reviewer is recorded, not `not assigned`.
4. **Test the gate itself.** A CI job that runs `release-readiness.sh` against a
   fixture with the marker removed and asserts a non-zero exit. An untested gate
   is an assumption.
5. **Keep the greps** as a cheap belt-and-braces layer — they are not harmful,
   they are just not sufficient.

**Blocker:** **Yes.** The control that prevents shipping unfinished cryptography
can be disabled by a rename.

---

## R3

### No vulnerability scanning in CI; the I27 exception has no tripwire

**Severity:** High
**Location:** [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) — six jobs (`server`, `crypto`, `mobile`, `mobile-ios`, `compose-smoke`, `licenses`), none of which scans for vulnerabilities; [`scripts/audit-rust.sh:12`](../../scripts/audit-rust.sh#L12)

**Problem**

`scripts/audit-rust.sh` exists and encodes carefully reasoned, **time-bounded**
exceptions for six advisories in the OpenMLS 0.8.1 / hpke-rs 0.6 graph. Its own
comment states the terms:

```sh
# support for hpke-rs 0.7+; next mandatory review: 2026-08-29.
```

`docs/board.md:126` repeats it: *"Re-review is mandatory by 2026-08-29."*

**Nothing enforces that date.** The script is not invoked by any CI job, so:

- the exceptions do not expire — after 2026-08-29 they silently continue to apply;
- a new advisory in the Rust graph is not detected until someone runs the script
  by hand;
- the guard the script does implement — failing if the optional libcrux AEAD
  crates enter the build graph, or if the pinned ciphersuite changes — never runs,
  so the condition it protects can be violated without anyone noticing.

`govulncheck` has the same problem in reverse. The board records that it was run
and cleared (`board.md:206`, `board.md:237`), but no CI job runs it, so that
result is a snapshot bound to one commit and one toolchain — and per [R1](#r1),
not the toolchain the container uses.

There is also no `dependency-review` action on pull requests, so a Dependabot PR
introducing a vulnerable transitive dependency has nothing checking it.

**Why it matters in production**

The I27 card is well reasoned — the analysis of why the SHAKE/secrets advisories
are unreachable under the pinned X25519 ciphersuite is genuinely careful work.
That work has a shelf life, and the mechanism that was supposed to enforce the
shelf life is a comment in a shell script nobody runs.

The re-review deadline is **2026-08-29**. At the time of this audit that is
three weeks away, and the only thing that will cause it to happen is a human
remembering.

For a cryptography-dependent product, "we tracked our advisory exceptions in a
comment" is not a defensible answer to a security reviewer, and card **I25**
requires exactly that reviewer.

**Fix**

1. **Add a `security` job to CI** running on push, pull request, **and a daily
   schedule**:
   - `govulncheck ./...` in `server/`
   - `cargo audit` via `scripts/audit-rust.sh` in `crypto/rust/`
   - `flutter pub outdated` / `pub audit` for the Dart graph
   The daily schedule is the important part: a new advisory should surface
   without anyone pushing code.
2. **Make the exception deadline executable.** Have `audit-rust.sh` read the
   expiry date from a structured file (e.g. `deny.toml` or a small JSON manifest
   listing advisory ID, rationale, and `expires`) and **exit non-zero once the
   date has passed**. Then the deadline enforces itself and the failure lands in
   CI rather than in someone's memory.
3. **Wire it into [R2](#r2)** so the release gate cannot pass with an expired
   exception.
4. **Add `actions/dependency-review-action`** on pull requests so Dependabot PRs
   are checked before merge.
5. **Consider OpenSSF Scorecard** — this repository would score well already, and
   for an AGPL security product that is a meaningful public signal.

**Blocker:** **Yes.** Not because the current exceptions are wrong — they are
well argued — but because nothing will tell anyone when they stop being valid.

---

## R4

### Shutdown grace, drain deadline and upload timeout contradict each other

**Severity:** Medium
**Location:** [`deploy/docker-compose.yml:42`](../../deploy/docker-compose.yml#L42), [`server/internal/app/app.go:180`](../../server/internal/app/app.go#L180), [`server/internal/app/app.go:210-216`](../../server/internal/app/app.go#L210-L216), [`docs/operations.md:37-40`](../../docs/operations.md#L37-L40)

**Problem**

Four numbers describe the same shutdown and none of them agree:

| Setting | Value | Source |
| --- | --- | --- |
| Compose `stop_grace_period` | 30 s | `docker-compose.yml:42` |
| `server.Shutdown` timeout | 25 s | `app.go:180` |
| Attachment/backup route deadline | **15 min** | `app.go:211-213` |
| Account-export route deadline | 5 min | `app.go:214-215` |

`docs/operations.md:37-40` states shutdown *"lets active HTTP uploads finish
within the server's 25-second shutdown deadline."*

An upload route is explicitly given 15 minutes because a 50 MB attachment over a
slow mobile uplink genuinely needs it. It therefore cannot finish within a
25-second drain, and after 30 seconds Docker sends `SIGKILL` regardless.

The stated behaviour is not achievable by construction: the drain window is 25
seconds and the operation it claims to protect is allowed 36× that.

**Why it matters in production**

Every routine restart — an upgrade, a config change, a host reboot — kills any
upload older than 25 seconds. The client's outbox handles it correctly (the
request never completed, so it retries), so this is not data loss. It is wasted
work and wasted mobile data, repeated on every restart, and the server leaves a
partial `.tmp` file behind each time (cleaned up later by `CleanupTemporaryFiles`,
which is good — but it means a restart during a busy period leaves a pile of
partials).

The documentation problem is the more serious half: an operator reading
`operations.md` will believe uploads are protected and will not think about it
again.

**Fix**

1. **Correct the documentation first.** State plainly that in-flight uploads
   longer than the drain window are terminated and retried by the client. That is
   acceptable behaviour; it just has to be the documented behaviour.
2. **Pick a coherent set of numbers.** Either:
   - accept the truncation and align them — e.g. `stop_grace_period: 40s`, drain
     30 s, and say so; or
   - genuinely protect uploads — track in-flight upload count, drain until it
     reaches zero or a longer ceiling (say 120 s) elapses, and raise
     `stop_grace_period` above it.
3. **Make them configurable and derived.** One
   `PRIVATE_MESSENGER_SHUTDOWN_TIMEOUT` that the server uses and the deployment
   examples reference, so they cannot drift apart again.
4. **Add the systemd unit to the same review** —
   `deploy/systemd/private-messenger.service` should carry a `TimeoutStopSec`
   consistent with whatever is chosen.
5. **Log the drain outcome**: how many requests were still in flight when the
   deadline expired. Currently a truncated shutdown is silent.

**Blocker:** No.

---

## R5

### No down migrations; any rollback across one is a full restore

**Severity:** Medium
**Location:** [`server/migrations/`](../../server/migrations/) — 23 forward-only `.sql` files; [`server/internal/storage/sqlite.go:278-339`](../../server/internal/storage/sqlite.go#L278-L339); documented at [`docs/operations.md:34-35`](../../docs/operations.md#L34-L35)

**Problem**

Migrations run forward automatically at boot and are checksummed — modifying an
applied migration produces a hard startup failure, which is exactly right. There
are no down migrations, and `Migrate` has no reverse path.

The documented consequence is honest:

> *"If rollback crosses an incompatible migration, stop the server, restore the
> matching pre-upgrade backup, and reinstall its matching binary."*

The gap is the phrase **"incompatible migration"**. Nothing tells an operator
which migrations are incompatible. There is no per-release note, no minimum
schema version recorded in the binary, and no startup check that a newer database
is being opened by an older binary.

So an operator who downgrades the container tag after a bad upgrade gets one of
three outcomes depending on what changed: it works, it fails loudly, or **it
appears to work while silently ignoring columns the newer schema added** — which
is the dangerous one, because writes proceed against a schema the binary does not
fully understand.

**Why it matters in production**

Self-hosters roll back. It is the standard response to any problem after an
upgrade, and it is a single `docker compose` command away. The runbook is correct
but requires a good, recent, verified backup, which is the thing most likely to be
missing — and [R8](#r8) notes that no shipped deployment automates one.

**Fix**

1. **Record a schema floor in the binary.** Store the highest migration version
   the binary understands; refuse to start if the database has applied a higher
   one, with a message naming the required version. This turns the dangerous
   silent case into a clear one and costs a constant plus a query.
2. **Mark migrations as compatible or breaking.** A header comment convention
   (`-- breaking: true`) plus a generated table in the release notes tells the
   operator whether a given downgrade is safe without reading SQL.
3. **Make the runbook executable.** `messenger-server doctor` should report the
   applied schema version and whether it matches the binary, so the pre-upgrade
   check is one command.
4. **Verify the backup before upgrading.** `docs/operations.md:30` says "run a
   completed backup" — add "and verify it with
   `messenger-server restore --dry-run`", which `ValidateDatabaseFile`
   (`sqlite.go:152-192`) already implements the logic for.
5. **Test one downgrade** as part of the release matrix: upgrade, write data,
   downgrade, observe the failure mode. Currently nobody knows which of the three
   outcomes occurs.

**Blocker:** No — the risk is documented and the restore path works.

---

## R6

### No golden tests, and the visual rebuild was never rendered

**Severity:** Medium
**Location:** [`mobile/test/`](../../mobile/test/) — 13 test files, no `*.png` goldens, no `matchesGoldenFile`

**Problem**

The board is admirably direct about this (`docs/board.md:109-112`):

> *"Not covered by this run: golden tests (none exist), Android and iOS builds,
> the Compose smoke, and every manual and accessibility check in I24. Rendering
> was never executed — `flutter test` does not prove the screens **look** right,
> only that they build, analyze, and keep their contracts."*

That is accurate, and it applies to an **uncommitted, complete visual rebuild** of
every screen in the application. The 2026-08-08 verification run was the first
time the I28 tree was executed at all, and it immediately found two real defects
by running — a `TileGroup`/`ListTile` `Material` ancestor assertion that would
have fired on five screens, and a profile-screen test that could no longer reach
its target because the taller layout pushed it below the viewport.

Both were found by *executing* what inspection had missed. That is the strongest
possible argument that this codebase needs rendering coverage, and it is the
argument the board itself makes.

Related gaps in the same area:

- **No test at a non-default text scale.** Several findings in
  [`ui-issues.md`](ui-issues.md) ([U11](ui-issues.md#u11), [U16](ui-issues.md#u16),
  [U20](ui-issues.md#u20)) are overflow or truncation risks that only appear at
  150–200% scale — exactly the scale card I24 requires testing manually.
- **No test at a small width or in landscape.**
  [`ui-issues.md` U6](ui-issues.md#u6) (master-detail firing in phone landscape)
  is a two-line layout bug that a 850 × 390 widget test would catch instantly.
- **No contrast assertion.** [`ui-issues.md` U1](ui-issues.md#u1) is a WCAG 1.4.11
  failure computable from the token values in pure Dart.
- **No integration test for the crypto-gated paths.** They cannot be exercised
  end-to-end today, which is correct — but there is also no test asserting they
  remain *unavailable*, so a partial unwiring could pass CI.

**Why it matters in production**

79 tests pass, `flutter analyze` is clean, and none of that would have caught the
`TileGroup` defect that would have crashed five screens in any debug run. The
suite proves the widget tree constructs; it does not exercise layout, paint, or
constraint resolution. The uncommitted rebuild is precisely the change that most
needs those.

**Fix**

Ranked by value per unit of effort:

1. **Add golden tests for six screens** — chat list (empty, populated), a
   conversation, connect, settings, conversation details — in light and dark. Run
   them in CI on a pinned Flutter version so rendering differences are the only
   variable. This is the single highest-value testing addition available and it
   locks in the visual rebuild permanently.
2. **Add a text-scale matrix.** The same widgets at 1.0×, 1.5× and 2.0×,
   asserting no overflow. Catches [U11](ui-issues.md#u11),
   [U16](ui-issues.md#u16) and [U20](ui-issues.md#u20) in one pass.
3. **Add a layout-size matrix** at 320 × 640 (small phone), 850 × 390 (phone
   landscape) and 1024 × 768 (tablet), asserting the correct shell branch. Catches
   [U6](ui-issues.md#u6).
4. **Add a contrast unit test** over the token pairs, asserting ≥4.5:1 for text
   and ≥3:1 for control boundaries. Pure computation, no rendering needed,
   and it makes the claim in `docs/design.md:99` machine-checked.
5. **Add a gate-integrity test** asserting the crypto-gated affordances remain
   unavailable while `UnavailableCryptoService` is wired — so a partial unwiring
   fails CI rather than shipping.
6. **Report coverage** ([R7](#r7)) so the gaps are visible rather than inferred.

**Blocker:** No — but item 1 should land **with** the I28 commit, not after it.
The rebuild is unverified visually, and goldens are what convert it from
"inspected" to "pinned".

---

## R7

### Coverage is measured and then discarded

**Severity:** Low
**Location:** [`.github/workflows/ci.yml:24`](../../.github/workflows/ci.yml#L24)

**Problem**

```yaml
- name: Test with race detector and coverage
  run: go test -race -coverprofile=coverage.out ./...
```

`coverage.out` is written and never read. It is not uploaded as an artefact, not
summarised in the job output, not compared against a threshold, and not tracked
between runs. The flag costs test time and produces nothing.

The Dart and Rust suites do not collect coverage at all.

**Why it matters in production**

Nobody can currently answer "is the retention sweeper tested?" or "is the outbox
failure-classification path covered?" without reading the tests. Several findings
in [`logical-issues.md`](logical-issues.md) sit in code paths that look plausibly
untested — [L5](logical-issues.md#l5) (single-page prune), [L6](logical-issues.md#l6)
(prune scope mismatch) and [L10](logical-issues.md#l10) (507 classification) are
all the kind of defect a coverage report points at directly.

**Fix**

1. Print a summary in the job log:
   `go tool cover -func=coverage.out | tail -1`. One line, immediate value.
2. Upload `coverage.out` as a workflow artefact so it can be diffed between runs.
3. Add a floor once the current number is known — a ratchet that can only go up
   is more useful than an aspirational target.
4. Add `flutter test --coverage` and `cargo llvm-cov` for the other two
   languages, so all three are visible.
5. Do **not** treat coverage as a quality target. Use it to find untested
   branches, which is what it is good for.

**Blocker:** No.

---

## R8

### No automated backup in any shipped deployment

**Severity:** Medium
**Location:** [`deploy/docker-compose.yml`](../../deploy/docker-compose.yml), [`deploy/systemd/private-messenger.service`](../../deploy/systemd/private-messenger.service), [`docs/operations.md:42-57`](../../docs/operations.md#L42-L57)

**Problem**

The backup machinery is good: `messenger-server backup <dir>` uses SQLite
`VACUUM INTO` for an atomic single-file copy without blocking writers
(`sqlite.go:259-276`), `restore` exists, `ValidateDatabaseFile` runs
`quick_check` plus a foreign-key check plus a schema-presence check, blob
references are enumerated, and `docs/operations.md` documents a full off-host
restore drill that was actually performed.

None of it runs unless a human runs it. Neither the Compose file nor the systemd
unit schedules a backup. There is no sidecar, no timer, no cron example, and no
retention policy for backup directories.

**Why it matters in production**

This is a single-node SQLite deployment. The database file **is** the instance —
accounts, devices, memberships, sync events, and the encrypted envelopes. There is
no replica and no managed snapshot. The entire durability story is "the operator
takes backups", and nothing in the product prompts, schedules, or verifies that.

It compounds directly with [R5](#r5): the documented rollback procedure is
"restore the matching pre-upgrade backup". If no backup exists, there is no
rollback — only data loss.

Self-hosters are precisely the population most likely to skip this, and this is
the product category where losing the database means losing every user's account
and every conversation on the instance.

**Fix**

1. **Ship a backup profile in Compose.** A small sidecar running
   `messenger-server backup` on a schedule into a mounted host directory, behind
   `profiles: ["backup"]` so it is opt-in but present and documented.
2. **Ship a systemd timer** alongside the unit, doing the same.
3. **Add retention**: keep N daily and M weekly, prune the rest. Backups that
   fill the volume are their own outage.
4. **Verify automatically.** After each backup, run `ValidateDatabaseFile` against
   the result and log the outcome. An unverified backup is a hope.
5. **Surface the state.** Report the last successful backup time in
   `messenger-server doctor` and as a metric, so "when did this last work?" is
   answerable.
6. **Warn on first start** if no backup configuration is detected — a one-line
   startup log pointing at `docs/operations.md`.
7. **Document blob backup explicitly.** `VACUUM INTO` covers the database;
   `blobs/` is a separate directory and needs its own copy. `docs/operations.md`
   says to copy "the whole directory", which is correct, but the distinction
   deserves to be explicit given that attachments are encrypted and
   irrecoverable if lost.

**Blocker:** No — the capability exists — but it is the highest-consequence
operational gap in the deployment story.

---

## R9

### Compose service lacks `cap_drop` and `read_only`

**Severity:** Low
**Location:** [`deploy/docker-compose.yml:35-53`](../../deploy/docker-compose.yml#L35-L53)

**Problem**

The container is already well hardened: `FROM scratch` (no shell, no package
manager, minimal attack surface), non-root UID 65532, `no-new-privileges:true`,
`mem_limit: 1g`, `pids_limit: 256`, loopback-only port binding, and bounded log
rotation. That is a stronger baseline than most deployments ship with.

Three cheap additions are missing:

- **`cap_drop: [ALL]`** — the process binds port 8080 (above 1024) as a non-root
  user and needs no Linux capabilities at all.
- **`read_only: true`** with the data volume writable — a scratch image has no
  reason to write outside `/data`.
- **`user: "65532:65532"`** — the Dockerfile sets it, but declaring it in Compose
  makes it explicit and prevents an override from silently escalating.

**Why it matters in production**

Each is one line and each removes a category of post-compromise movement. For a
product whose value proposition is protecting user data, matching the
already-strong container posture in the orchestration file is worth doing.

**Fix**

```yaml
    user: "65532:65532"
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
```

Verify the readiness probe still passes — `LocalStore.Check`
(`uploads/local.go:84-107`) writes a temp file into the blob root, which is on the
mounted volume and therefore writable. Add a `tmpfs: [/tmp]` mount if anything
else needs scratch space.

Consider also adding a seccomp profile reference and documenting rootless Podman
as a supported option, both of which suit this audience.

**Blocker:** No.

---

## R10

### The product has two names throughout

**Severity:** Medium
**Location:** repository-wide

**Problem**

The product is Veritra. The codebase is substantially still "private-messenger":

| Surface | Value | Seen by |
| --- | --- | --- |
| Go module | `private-messenger/server` | developers |
| Binary | `messenger-server` | **operators** |
| Database file | `private-messenger.db` | **operators** |
| Env var prefix | `PRIVATE_MESSENGER_*` (30+ variables) | **operators** |
| Compose service | `messenger` | **operators** |
| systemd unit | `private-messenger.service` | **operators** |
| Env example | `private-messenger.env.example` | **operators** |
| HTTP header | `X-Private-Messenger-Encrypted` | API consumers |
| Dart package | `private_messenger` | developers |
| pubspec description | "Client shell for Private Messenger" | developers |
| Android module | `private_messenger_android.iml` | developers |
| Rust crate | `private_messenger_crypto` | developers |
| Lock file | `.veritra-server.lock` | operators |
| Setup-token header | `X-Veritra-Setup-Token` | operators |
| Claim-token header | `X-Veritra-Claim-Token` | clients |
| Deep-link scheme | `veritra://` | users |
| App display name | Veritra | **users** |

The Veritra name has reached the user-facing surfaces, the branding, and the
newer headers. It has not reached the operator-facing surfaces, and the two
conventions now sit side by side — `X-Veritra-Setup-Token` and
`X-Private-Messenger-Encrypted` are set on requests to the same server.

**Why it matters in production**

Operator experience is the product for a self-hosted application. Someone
following `docs/operations.md` configures `PRIVATE_MESSENGER_*` variables for a
service called `messenger` producing `private-messenger.db`, guarded by
`.veritra-server.lock` — and reasonably wonders whether they have the right
software, or whether the documentation is stale.

More practically: **this only gets harder after release.** Renaming an
environment variable after operators have deployed means a compatibility shim and
a deprecation window. Before the first release it is a mechanical change.

**Fix**

1. **Decide now, before v1.** Either commit to Veritra everywhere or accept
   `private-messenger` as the internal identifier and stop introducing
   `X-Veritra-*` names. The current split is the only option that is wrong.
2. **If renaming, prioritise the operator surface** — env vars, binary,
   database filename, service and unit names — since those are the ones that
   become compatibility obligations.
3. **Support both env prefixes for one release** with a deprecation warning, so
   the change is safe even for the small number of existing deployments.
4. **Rename the internal identifiers** (Go module, Dart package, Rust crate,
   `.iml` files) in one mechanical commit; they are invisible to users and cost
   nothing later.
5. **Fix the header** — `X-Private-Messenger-Encrypted` is a required request
   header on uploads (`content_handlers.go:21`, `:136`), so changing it is a
   client-visible API change. Do it before there are third-party clients.
6. **Update `pubspec.yaml`** — see [R11](#r11).

**Blocker:** No — but the cost of deferring is real and rises at release.

---

## R11

### `pubspec.yaml` identity is stale

**Severity:** Low
**Location:** [`mobile/pubspec.yaml:1-4`](../../mobile/pubspec.yaml#L1-L4)

**Problem**

```yaml
name: private_messenger
description: Mobile-first client shell for Private Messenger.
publish_to: "none"
version: 0.1.0+1
```

Three issues. The name and description predate the rebrand ([R10](#r10)). The
description calls it a "client shell", which understates 16k lines of implemented
client. And `version: 0.1.0+1` is the Flutter template default — it becomes
`CFBundleShortVersionString` / `versionName` on both platforms via
`$(FLUTTER_BUILD_NAME)` and `$(FLUTTER_BUILD_NUMBER)`, so **every build ships as
version 0.1.0 build 1**.

**Why it matters in production**

Both stores reject a build whose version and build number have not increased, so
this must change before the first submission regardless. More usefully: with no
version in the app ([`ui-issues.md` U13](ui-issues.md#u13)) and no version in the
pubspec, a bug report cannot be tied to a build — which matters more here than
usual, because every self-hosted instance may run a different server version
against a different client version.

**Fix**

1. Set a real version and derive the build number from CI (`$GITHUB_RUN_NUMBER`
   or a monotonic counter) so it always increases.
2. Update the name and description with the [R10](#r10) decision.
3. Surface version, build number and commit in the app's About section
   ([`ui-issues.md` U13](ui-issues.md#u13)).
4. Report the server version too — the release workflow already injects
   `-X main.version` and `-X main.commit` (`release.yml:35`), but no API endpoint
   exposes them. Adding them to `/api/v1/setup/status` or a `/api/v1/version`
   endpoint would let the client display both halves, which is what a support
   conversation actually needs.

**Blocker:** No — but required before store submission.

---

## R12

### No export-compliance key; every upload will prompt

**Severity:** Low
**Location:** [`mobile/ios/Runner/Info.plist`](../../mobile/ios/Runner/Info.plist)

**Problem**

`ITSAppUsesNonExemptEncryption` is absent. Without it, App Store Connect prompts
for export-compliance information on **every** build upload and blocks TestFlight
distribution until answered.

Veritra uses non-exempt encryption in the ordinary sense — MLS, AES-256-GCM,
ChaCha20 for local storage — but end-to-end encryption in a messaging app is
typically covered by the mass-market exemption under EAR 5D002, which usually
requires a one-time self-classification report rather than per-build answers.

**Why it matters in production**

Purely process, but it lands on the critical path of card **I24** step 1 (build
signed release candidates) and step 2 (generate release artefacts). Discovering it
during the first upload attempt costs a day.

**Fix**

1. Add the key with the correct value for the determination made. If the
   mass-market exemption applies, set `ITSAppUsesNonExemptEncryption` to `false`
   only if that is genuinely accurate; otherwise set `true` and add
   `ITSEncryptionExportComplianceCode` after filing.
2. **Get the determination reviewed** — this is a legal classification, not an
   engineering one, and it should be recorded alongside the AGPL and third-party
   licence decisions the project already tracks carefully.
3. Note the equivalent for Google Play (US export compliance declaration in the
   Play Console).
4. Record the answer in `docs/operations.md` or a release runbook so it is not
   re-derived each time.

**Blocker:** No — but resolve it before the first TestFlight upload.

---

## R13

### iOS lacks the background modes and CallKit path calls require

**Severity:** High (for the calls feature)
**Location:** [`mobile/ios/Runner/Info.plist`](../../mobile/ios/Runner/Info.plist) — `UIBackgroundModes` contains only `remote-notification`

**Problem**

Calls are in release scope. Decision **D03** on the board reads: *"Keep native
APNs/FCM and calls in the current release scope."* Card **I24** step 4 requires
testing "a TURN call across network changes". `flutter_webrtc` 1.6.0 is a pinned
dependency and `calls/call_service.dart` is implemented.

The iOS configuration cannot support it:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
</array>
```

Three separate gaps:

1. **No `audio` background mode.** An active call is terminated when the app is
   backgrounded — so answering a call and then switching apps, or locking the
   screen, ends it.
2. **No `voip` background mode and no PushKit/CallKit integration.** On iOS, an
   incoming call to a backgrounded or terminated app requires a PushKit VoIP push.
   Since iOS 13 Apple *requires* that every PushKit push be reported to CallKit
   via `CXProvider.reportNewIncomingCall` in the same run loop, or the app is
   terminated and repeat offenders lose VoIP push entitlement. There is no
   PushKit registration, no `CXProvider`, and no CallKit code anywhere in the
   iOS runner.
3. **A standard APNs `remote-notification` push cannot substitute.** It is
   throttled, may be delayed or coalesced, and does not reliably wake a terminated
   app — so incoming calls would be missed or arrive late.

The net effect: **iOS cannot receive an incoming call at all** unless the app is
already in the foreground, and cannot sustain one across backgrounding.

**Why it matters in production**

The blocking is on card I24 itself. Its step 4 cannot pass on iOS regardless of
TURN credentials or hardware availability, because the app has no mechanism to be
woken for a call. That is currently recorded as "Pending TURN/hardware" in the
board's real-device matrix — the real blocker is a configuration and integration
gap that no amount of hardware will resolve.

There is also a design tension worth surfacing early: CallKit reports call
metadata to the system, and on some configurations to the carrier. For a product
whose stated boundary is that push carries no sender name and no content, the
CallKit integration needs a deliberate decision about what the system is told.
That is a privacy question, not just an engineering one, and it should be answered
before the code is written.

**Fix**

1. **Add the background modes**: `voip` and `audio` alongside
   `remote-notification`.
2. **Implement PushKit + CallKit.** Register for VoIP pushes, and report every
   received push to `CXProvider` immediately. This is mandatory, not optional.
   `flutter_callkit_incoming` or `callkeep` are the common Flutter routes; either
   is a new dependency and needs licence review per `AGENTS.md`.
3. **Extend the server's push provider.** A VoIP push uses a different APNs
   topic (`<bundle-id>.voip`) and a separate certificate/key. `push/native.go`
   currently sends one notification shape; call signalling needs its own path.
4. **Decide the privacy posture explicitly** and record it as a board decision:
   what is displayed in the CallKit UI, whether calls appear in the system recents
   list (`CXProviderConfiguration.includesCallsInRecents`), and what the VoIP push
   payload contains. Default to the most conservative option consistent with a
   usable call.
5. **Add `NSMicrophoneUsageDescription`** — already present and well worded.
   Also add `NSCameraUsageDescription` coverage for video calls; the current
   string mentions only QR scanning, which would be a misleading permission prompt
   if video calling ships.
6. **Update the board.** Move the iOS call rows in the real-device matrix from
   "Pending TURN/hardware" to a distinct blocked-on-implementation state, so the
   dependency is visible.

**Blocker:** **Yes**, for calls and for completing I24. Not for a release that
explicitly defers calls — which is a legitimate option worth considering given the
scope involved.

---

## R14

### Android lacks the foreground-service type calls require

**Severity:** High (for the calls feature)
**Location:** [`mobile/android/app/src/main/AndroidManifest.xml`](../../mobile/android/app/src/main/AndroidManifest.xml)

**Problem**

The manifest declares `INTERNET`, `CAMERA`, `RECORD_AUDIO`,
`MODIFY_AUDIO_SETTINGS` and `BLUETOOTH_CONNECT` — the right permissions for
WebRTC. It does not declare any foreground service for calls.

Since Android 14 (API 34), a service that captures microphone input while the app
is not visible must be a foreground service with type
`microphone` (and `camera` for video), declared in the manifest **and** backed by
the matching `FOREGROUND_SERVICE_MICROPHONE` / `FOREGROUND_SERVICE_CAMERA`
permissions. Without that, the OS blocks microphone capture the moment the app
leaves the foreground — so an active call goes silent when the user switches apps
or the screen locks.

Additionally missing:

- **`POST_NOTIFICATIONS`** (Android 13+) — covered in
  [`security-issues.md` S12](security-issues.md#s12), and required here too since
  a foreground service must post an ongoing notification.
- **`USE_FULL_SCREEN_INTENT`** — needed to present a full-screen incoming-call UI
  on a locked device.
- **`WAKE_LOCK`** — commonly required to keep the connection alive during a call.

The two push services that *are* declared (`VeritraPushService` for UnifiedPush,
`VeritraFirebaseMessagingService` for FCM) are correctly `exported="false"`, which
is right.

**Why it matters in production**

Same shape as [R13](#r13): card I24 step 4 ("test a TURN call across network
changes") cannot pass on Android 14+ either, because backgrounding the app kills
the audio capture. And Android 14+ is the majority of active devices.

The board records this as pending hardware and TURN. The hardware will not fix it.

**Fix**

1. **Add the permissions**:
   ```xml
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
   <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
   <uses-permission android:name="android.permission.WAKE_LOCK" />
   ```
   Add `FOREGROUND_SERVICE_CAMERA` only if video calling ships.
2. **Declare a call foreground service** with
   `android:foregroundServiceType="microphone"`, started when a call becomes
   active and stopped when it ends, posting an ongoing call notification.
3. **Use ConnectionService** (Android's CallKit counterpart) for a native
   incoming-call experience — the same package choice as [R13](#r13) usually
   covers both platforms.
4. **Add `android:enableOnBackInvokedCallback="true"`** while editing the
   manifest — Android 13+ predictive back, unrelated to calls but a one-line
   modernisation.
5. **Justify the permissions for Play review.** `RECORD_AUDIO` plus a
   full-screen-intent permission attracts scrutiny; prepare the declaration.
6. **Update the board** for the same reason as [R13](#r13): distinguish
   blocked-on-implementation from blocked-on-hardware.

**Blocker:** **Yes**, for calls and for completing I24.

---

## R15

### iOS cannot reach a LAN server

**Severity:** Medium
**Location:** [`mobile/ios/Runner/Info.plist`](../../mobile/ios/Runner/Info.plist) — no `NSLocalNetworkUsageDescription`

**Problem**

Since iOS 14, any connection to a local-network address (`192.168.x.x`,
`10.x.x.x`, `.local`, and multicast/broadcast) triggers a system permission
prompt, and the app must declare `NSLocalNetworkUsageDescription` or the
connection is refused outright.

That key is absent. Combined with cleartext being blocked
([`ui-issues.md` U2](ui-issues.md#u2)) and no path to trust a self-signed
certificate ([`security-issues.md` S8](security-issues.md#s8)), an iOS device
**cannot connect to a self-hosted Veritra server on a home or office network at
all**, by any route.

**Why it matters in production**

"Self-hostable" is the first claim in the product description, and the roadmap
names a *"self-hosted internal-network deployment"* as an explicit Phase 2 target
(`docs/board.md`, Phase 2). The most natural first deployment for a privacy-minded
user — a server on their own LAN, reached from their own phone — is currently
impossible on iOS and undiagnosable, because the failure is a socket error with no
explanation.

**Fix**

1. **Add `NSLocalNetworkUsageDescription`** with an honest string:
   *"Veritra connects to a Veritra server you host on your own network."*
2. **Resolve it together with [S8](security-issues.md#s8) and
   [U2](ui-issues.md#u2)** — the LAN case needs all three answered (local network
   permission, certificate trust, and cleartext policy) or none of them helps.
3. **Document the supported LAN path** in `docs/operations.md`: most likely Caddy
   with `tls internal`, plus distributing the CA certificate to devices. That is a
   real, workable answer; it just has to be written down.
4. **Test it.** Add "connect to a LAN-hosted instance" to the I24 device matrix.
   It is currently not listed, which is why the gap was not caught.

**Blocker:** No — but it blocks a stated use case and is one plist key plus
documentation.

---

## R16

### Stray empty directory beside the repository

**Severity:** Low
**Location:** `c:\Users\V\Documents\Veritra\Veritra;C` (outside the repository)

**Problem**

An empty directory named `Veritra;C` sits next to the repository root, almost
certainly created by a shell command where a `;C` fragment was interpreted as part
of a path — a common PowerShell/`cd` accident on Windows.

It is outside the repository and not tracked by git, so it affects nothing in the
build. Noting it because it is the kind of artefact that gets swept into a backup
or an archive and then puzzles someone later.

**Fix**

Delete it. Verify it is empty first — this audit observed it as empty, but confirm
before removing anything.

**Blocker:** No.

---

# Release readiness summary

## Blocking

| # | Finding | Why it blocks |
| --- | --- | --- |
| 1 | **[R1](#r1)** | Container and tarball are different programs under one release identity; vulnerability evidence covers only one |
| 2 | **[R2](#r2)** | The gate preventing an unfinished-crypto release can be disabled by a rename |
| 3 | **[R3](#r3)** | Advisory exceptions expire 2026-08-29 with nothing enforcing the date; no scanning in CI |
| 4 | **[R13](#r13)** / **[R14](#r14)** | Calls (in scope per **D03**) cannot work on either platform as configured; card **I24** step 4 is blocked on implementation, not hardware |

## Correcting the board

Two entries in the release-evidence matrix should be re-stated:

- **Real-device call rows** are listed as "Pending TURN/hardware". They are
  blocked on iOS/Android platform integration ([R13](#r13), [R14](#r14)) that no
  hardware or TURN deployment will resolve. Worth splitting into a distinct
  blocked-on-implementation state so the dependency is visible.
- **"Go vulnerability scan — Pass — Go 1.25.12"** is accurate for the tarball
  binaries and inaccurate for the published container, which is built with 1.26.4
  ([R1](#r1)). Add a toolchain column so each row states what it covers.

Both are small documentation changes, and the board's accuracy is one of this
project's genuine strengths — worth preserving precisely.

## Sequencing

**Before the next tag:** [R1](#r1), [R2](#r2), [R3](#r3). All three are CI and
scripting changes measured in hours, and each protects everything downstream of
it. Do these first — they are the cheapest high-value work in this entire audit.

**Before card I24 resumes:** [R13](#r13), [R14](#r14), [R15](#r15), and
[`security-issues.md` S12](security-issues.md#s12). Real-device testing will
otherwise produce misleading results — push wake will appear broken when the
permission is missing, and calls will appear broken when the service type is.

**Before the I28 tree is committed:** [R6](#r6) item 1 (goldens for six screens).
The rebuild is visually unverified, and goldens are what convert it from
"inspected" to "pinned". The two defects the first execution found are the
argument.

**Before v1.0:** [R10](#r10) (name decision — the cost rises sharply at release),
[R11](#r11), [R12](#r12), [R8](#r8) (backup automation), [R4](#r4)
(shutdown documentation).

**First maintenance cycle:** [R5](#r5), [R7](#r7), [R9](#r9), [R16](#r16).
