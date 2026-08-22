# T40B — Toolchain and packaged-artifact parity

| Field | Contract |
|---|---|
| Consensus source | I40; DEP-06, R1 |
| Initial eligibility | Ready after T40A |
| Risk | High release blocker |
| Executor | Balanced+advisor |
| Advisor | Review the single-source/version design before edits |
| Depends on | T40A |
| Blocks | G24 |
| Parallel safety | Do not overlap T46 artifact/Compose edits without one coordinator |

## Objective

Use one Go toolchain declaration across module, CI, release and container, and
test the exact container artifact that will be distributed.

## Read first

- `docs/audit-consensus.md` I40.
- `docs/audits-codex/deployment-risks.md` DEP-06.
- `docs/audits-opus/production-readiness.md` R1.
- `server/go.mod`, `server/Dockerfile`, `.github/workflows/ci.yml`,
  `.github/workflows/release.yml`, `deploy/docker-compose.yml`.

## Work

1. Confirm every current version source and drift.
2. Select one canonical source that automation can consume.
3. Make CI build and test the production container artifact.
4. Add a drift check that fails before publication.

## Acceptance

- Changing one noncanonical version cannot silently alter a build.
- CI-tested server version/toolchain equals the packaged image.
- Artifact digest flows into release evidence.

## Required checks

```sh
./scripts/test.sh
./scripts/lint.sh
```

