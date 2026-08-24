# T50 — Deferred product and ecosystem roadmap

| Field | Contract |
|---|---|
| Consensus source | I50; NTH-06, NTH-07, NTH-17, NTH-18, NTH-20; H2; rejected R16 and unnumbered ideas |
| Routing snapshot (board wins) | Deferred |
| Risk | Not a release blocker |
| Executor | Strong only after a trigger is approved |
| Advisor | Required for privacy/protocol/ecosystem boundary decisions |
| Depends on | D06/mobile release and an explicit product trigger |
| Blocks | Nothing in release one |
| Parallel safety | Do not spawn work from this file before a scoped child task is approved |

## Objective

Preserve deferred ideas without allowing them to distract from or weaken the
mobile release. This is an intake list, not a claimable implementation task.

## Retained themes

- Encrypted drafts/search, contacts, archive/pin and trust ceremonies.
- Trust center, admin/operator tools, moderation and auditable actions.
- Multi-account, passkeys, privacy/TLS indicators and post-quantum readiness.
- Privacy-safe CLI/API ecosystem, reproducible builds and F-Droid.
- Desktop after mobile release; embedding only after its E2EE/product trigger.

Federation, PostgreSQL, S3 and NATS remain out of scope. R16 remains rejected.

## Trigger protocol

1. Record the approved product trigger and why release work is no longer higher priority.
2. Re-audit current code and applicable standards; do not implement from old prose.
3. Create a new child task from `TASK_TEMPLATE.md` with exact privacy boundary,
   source files, dependency review, tests and rollback.
4. Use the strongest available model for protocol/privacy design; an advisor
   does not substitute for explicit product approval.

## Acceptance

T50 itself completes only when each retained theme is either converted to an
approved scoped child task, explicitly rejected, or deliberately left deferred.
