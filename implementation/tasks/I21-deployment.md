# I21 — Harden production deployment

Goal: the supported single-node deployment starts safely, runs one writer, and can be restored.

Read:

- `deploy/`, server startup/config, backup CLI
- `implementation/archive/2026-07-26/docs/deployment.md`
- release workflows and Dockerfile

Do:

1. Make production mode and one-time setup secret requirements explicit in Compose/systemd examples.
2. Enforce one writer per data directory with a tested process lock.
3. Add graceful drain/readiness behavior for uploads, realtime, and shutdown.
4. Provide a short upgrade/rollback/secret-rotation runbook and an off-host backup/restore drill.
5. Align pinned Go/Rust/Flutter build versions.

Done when: a fresh-volume smoke test, second-process rejection, graceful shutdown test, and clean-host restore all pass.

Verify: deployment tests, `docker compose config`, fresh Compose smoke, and aggregate gates.

Keep metrics local/privacy-safe; no telemetry service.
