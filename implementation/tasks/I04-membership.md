# I04 — Enforce DM and member lifecycle

Goal: DMs stay two-account conversations and groups support safe list/leave/remove flows.

Read:

- conversation domain/storage/handler files under `server/internal/`
- membership migrations and authorization tests
- `implementation/archive/2026-07-26/legacy-implementation/04-membership-and-safety.md` only if rules are unclear

Do:

1. Add tests proving a DM cannot gain a third account or duplicate pair.
2. Return an authorized roster with roles.
3. Implement self-leave and authorized removal with last-owner/rank checks.
4. Emit lifecycle events through I03's transaction pattern.
5. Represent pending MLS coordination honestly; server membership alone must not imply crypto completion.

Done when: invariants hold under retries and concurrent requests, with no cross-conversation disclosure.

Verify:

```powershell
Push-Location server; go test ./internal/storage ./internal/httpapi; Pop-Location
```
