# TXX — Task title

| Field | Contract |
|---|---|
| Consensus source | IXX; source finding IDs |
| Initial eligibility | Ready / Blocked / Prepared / Deferred / External |
| Risk | Severity and release effect |
| Executor | Strong / Balanced+advisor / Balanced |
| Advisor | Required checkpoint or “only if escalation trigger fires” |
| Depends on | Task IDs or — |
| Blocks | Task IDs or release gate |
| Parallel safety | Explicit safe and unsafe overlap |

## Objective

One observable outcome. State why it matters.

## Read first

- Exact section in `docs/audit-consensus.md`.
- Exact finding sections in source audits.
- Starting code and test paths. Verify before editing.

## Invariants

- Task-specific boundaries in addition to `AGENTS.md`.

## Work

1. Ordered implementation steps.

## Acceptance

- Observable pass/fail criteria.

## Required checks

```sh
# Narrow checks, then integration checks.
```

## Advisor checkpoint

The precise question and when to ask it.

## Handoff

Use the handoff block from `implementation/WORKFLOW.md` and identify every
criterion, skipped check and residual blocker.

