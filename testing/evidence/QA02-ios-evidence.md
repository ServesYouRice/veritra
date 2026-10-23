# QA02 — Separate simulator and signed-iOS evidence

Date: 2026-10-23. Base: `f8a08da`. Python 3.13, standard library only.
G24 stays pending, because no signed artifact, signing material or device
evidence exists. Release readiness stays blocked.

## Schema

`release/release-policy.json` moves to schema 2. Its new `mobile_artifacts`
block is protected: the checker requires it to equal its built-in constant.
The block requires exactly one `ios` + `signed-release` record and names
`mobile-ios` as the iOS simulator CI job. `mobile-ios` is still a required CI
job. The release manifest has a new `mobile_artifacts` list. Every record must
have exactly these keys:

| Key | `simulator-debug` (hosted CI) | `signed-release` (G24) |
|---|---|---|
| `schema` | `veritra-mobile-artifact/1` | same |
| `platform` | `ios` | `ios` |
| `commit`, `provenance.source_commit` | candidate | candidate |
| `file` | plain `*.zip` name | plain `*.ipa` name |
| `digest` | `sha256:` + 64 lowercase hex | same, recomputed from the file |
| `build` | `iphonesimulator`/`debug`, `main.dart` or `main_demo.dart` | `iphoneos`/`release`, `lib/main.dart` only |
| `signing` | `status: unsigned` | `signed`, `identity: distribution`, `verification: pass`, a verifier |
| `provenance` | GitHub Actions, `ci.yml`, job `mobile-ios` | GitHub Actions, any other workflow and job, run ID ≠ the CI run |

For a signed record, the `.ipa` must be in the artifacts directory
(`--artifacts-dir`, else `$MOBILE_ARTIFACTS_DIR`, else the evidence file's
directory). The checker reads it and requires:

- exactly one `Payload/*.app` bundle;
- Info.plist `DTPlatformName=iphoneos` and `CFBundleSupportedPlatforms=[iPhoneOS]`;
- `_CodeSignature/CodeResources`;
- an embedded profile with `get-task-allow=false`;
- every Mach-O slice is arm64, `LC_BUILD_VERSION` platform iOS (not
  simulator), with an `LC_CODE_SIGNATURE`.

The release is also blocked if:

- a signed record has the same digest as any simulator record;
- there are two signed records for the same platform;
- any record is stale or malformed, simulator records included.

These checks look at structure only. They do not check signatures
cryptographically. In hosted CI, `release.yml` then runs
`gh attestation verify` on each signed `.ipa` (signer workflow, source commit,
no self-hosted runners). If there is no signed record, that step fails.

Wiring:

- `mobile-ios` uploads `veritra-demo-ios-simulator.evidence.json` (a
  `simulator-debug` record) next to its zip.
- `write-release-evidence.py` reads signed records only from
  `MOBILE_ARTIFACTS_FILE`, never from CI evidence. If that file is missing,
  it fails.
- `release.yml` expects G24 to stage that file and the `.ipa` in
  `$RUNNER_TEMP/mobile-artifacts`, outside `dist/`, so nothing there is
  published. Nothing stages them yet.
- `check-ci-evidence.py` now requires each required job exactly once. A
  skipped duplicate `mobile-ios` no longer hides behind a successful one.

## Fixtures (`scripts/check-release-evidence_test.py`)

Every case starts from a fresh copy of valid evidence and must fail with its
own message.

- **Missing:** no list, empty list, list is not an array, `.ipa` absent,
  empty artifacts directory (flag and environment variable).
- **Simulator-only:** the record the CI writer produces is valid simulator
  evidence, but it alone blocks.
- **Simulator relabelled as signed:**
  - the record says signed-release;
  - simulator bytes wrapped as an `.ipa`;
  - a forged device plist over a simulator Mach-O;
  - fat binaries with simulator or x86_64 slices;
  - a signed record with the same digest as a simulator record.
- **Skipped simulator:** a valid signed artifact with `mobile-ios` skipped or
  absent still blocks.
- **Unsigned:**
  - the record honestly says unsigned;
  - the record claims signed, but the bytes have no code signature, no profile
    and no `LC_CODE_SIGNATURE`;
  - a development profile;
  - an unreadable profile;
  - an unverified signature or a non-distribution identity.
- **Wrong commit:** the record commit, or the provenance source commit.
- **Wrong platform:** `android`, `iOS`, `macos`, null.
- **Wrong type:**
  - `simulator-debug` on an `.ipa`;
  - unknown types;
  - `main_demo.dart`, debug, or the simulator SDK on a signed record.
- **Malformed digest:**
  - 63 hex characters, upper case, `sha1:`, no prefix, empty, a number;
  - a well-formed digest that does not match the bytes.
- **Provenance:**
  - `ci.yml`, job `mobile-ios`, or the CI run ID (also `"0123"`);
  - not GitHub Actions;
  - bad workflow paths;
  - run IDs that are not ASCII digits.
- **Schema and policy:**
  - extra or missing keys, wrong record schema, duplicate signed records;
  - a schema 1 manifest;
  - the requirement removed from or weakened in the policy.
- **Valid:** one synthetic signed `.ipa` passes. So does a fat device-only
  binary, an `.ipa` staged through `MOBILE_ARTIFACTS_DIR`, and the writer's
  manifest with a simulator record alongside. The profile, signature and code
  resources are placeholder bytes. No signing material is involved.

The CI and writer suites add these cases:

- a skipped, failed or absent `mobile-ios` gives no CI evidence;
- a skipped duplicate gives no CI evidence;
- CI evidence holds only job conclusions;
- CI evidence cannot inject mobile records;
- the simulator-record CLI works;
- a missing mobile artifact file fails the writer.

To prove the cases are not vacuous, I made 19 single mutations to the
checker. Each one made the suite fail.

## Results

| Check | Result |
|---|---|
| `python3 scripts/check-release-evidence_test.py` | pass |
| `python3 scripts/check-ci-evidence_test.py` | pass |
| `python3 scripts/write-release-evidence_test.py` | pass |
| `check-dart-retractions_test.py`, `check-coverage_test.py` | pass |
| `./scripts/release-readiness.sh` | blocked as expected: both approval files are missing |
| attestation step (stub `gh`) | 0 signed records fails; 1 and 2 records call `gh` once each |
| `./scripts/test.sh`, `./scripts/verify.sh` | not run: cold Rust build and a Flutter Docker image are too slow for a shared 4-CPU box; this diff changes no Go, Rust or Dart |

## Review (one review subagent, adversarial pass)

Adopted:

- **Run ID bypass.** `"0123"` and full-width digits got past the "not the CI
  run" check. Run IDs must now be ASCII digits and are compared as integers.
  Fixtures were added.
- **Self-asserted signature and provenance.** Added the
  `gh attestation verify` step in `release.yml`.
- **Mach-O bound.** Added a minimum size for `LC_BUILD_VERSION`.

Rejected:

- **Publishing the `.ipa`.** Ad-hoc profiles embed device UDIDs, and G24
  forbids publishing them. The signed build's attestation keeps the digest
  auditable.
- **Using the PR head SHA in the simulator record.** PR builds come from the
  merge commit, so naming the head would be false provenance. Release evidence
  uses push runs only.
- **Letting faulty simulator records pass.** They fail closed on purpose. The
  digest-collision check can only block, never admit.
- **Board and queue updates.** The coordinator owns them.
- **Writer and checker duplication.** Kept; the cross-test proves that the
  writer's record passes the checker as simulator-debug evidence.

## Open

- G24 must add the signed build. That build signs with protected secrets,
  runs `codesign --verify`, attests the `.ipa`, and stages
  `mobile-artifacts.json`.
- Android needs the same separation. The CI release APK is unsigned, and the
  policy does not require signed Android evidence yet.
- Approval files bind `reviewed_commit` to the candidate. A file committed in
  the candidate cannot contain that candidate's own SHA, so `release.yml`
  needs another way to receive approvals (an existing I40 design gap).
