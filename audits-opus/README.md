# audits-opus

Independent production-readiness audit of Veritra, performed 2026-08-08 against
the **working tree** (commit `d60e45b` plus the uncommitted I28 "K2 · Bone"
visual rebuild described in `docs/board.md`).

This is an **audit only**. No application code was read-modified. Every file in
this folder is a document.

> **Note on `AGENTS.md`.** That file says "Do not create documentation outside
> `docs/`." This folder was created at explicit user instruction, which
> supersedes it for this task. If the findings are adopted, the right long-term
> home is either `docs/` or `docs/archive/2026-08-08/audits-opus/`, matching how
> the earlier `audits-codex` / `audits-fable` passes were archived.

## Files

| File | What it covers |
| --- | --- |
| [`audit-plan.md`](audit-plan.md) | Stack inventory, user flows, method, scope, and what was **not** covered |
| [`ui-issues.md`](ui-issues.md) | Interface, UX, responsive behaviour, accessibility, forms, states |
| [`logical-issues.md`](logical-issues.md) | Correctness, async, state, data integrity, edge cases, production blockers |
| [`security-issues.md`](security-issues.md) | Auth, secrets, abuse prevention, attack surface |
| [`performance-issues.md`](performance-issues.md) | Query cost, hot paths, render cost, resource use |
| [`production-readiness.md`](production-readiness.md) | Build/release integrity, CI gates, deployment, platform config, testing gaps |
| [`nice-to-haves.md`](nice-to-haves.md) | Product completeness, polish, DX, architecture, roadmap |

## Headline

The engineering quality here is genuinely high — atomic write paths, an honest
fail-closed crypto gate, a thorough error catalogue, deliberate privacy
boundaries, and per-finding rationale left in the code. The board is an accurate
account of what is done. **This audit found no problem with the crypto boundary
itself.** What it found is a set of defects in the layers *around* it: silent
data loss in the client outbox, three ways for background sync to wedge
permanently, cost curves in the storage layer that only bite at real data
volumes, an accessibility failure baked into a single design token, and a
release pipeline whose gate is weaker than the evidence it guards.

**Six findings that must be fixed before any production release:**

| # | Finding | File |
| --- | --- | --- |
| 1 | Outbox silently deletes the **oldest** queued messages at 100 entries | [L1](logical-issues.md#l1) |
| 2 | One bad sync event permanently wedges catch-up for that device | [L2](logical-issues.md#l2) |
| 3 | MLS outbox has no error handling; one bad message blocks it forever | [L3](logical-issues.md#l3) |
| 4 | `resetOnError: true` silently destroys the local database key | [L7](logical-issues.md#l7) |
| 5 | Setup token has no entropy floor despite the docs promising one | [S1](security-issues.md#s1) |
| 6 | Container ships a Go toolchain that CI never tests | [R1](production-readiness.md#r1) |

## Recommended fix order

Ordered by (production impact × confidence) ÷ effort. Each block is
independently shippable.

### Block 1 — data-loss and wedge bugs (do first; all client-side, all small)

1. **[L1](logical-issues.md#l1)** Outbox cap deletes oldest messages silently — *Critical*
2. **[L7](logical-issues.md#l7)** `resetOnError: true` wipes the DB key — *High*
3. **[L2](logical-issues.md#l2)** Poison sync event wedges catch-up — *High*
4. **[L3](logical-issues.md#l3)** MLS outbox head-of-line block + unhandled async throw — *High*
5. **[L10](logical-issues.md#l10)** 507 quota errors retried forever — *Medium*

### Block 2 — server correctness (small, well-isolated, each has a test seam)

6. **[L5](logical-issues.md#l5)** Expired-message sweeper drains only 500 rows / 6 h — *High*
7. **[L6](logical-issues.md#l6)** Attachment prune deletes blobs whose DB rows survive — *High*
8. **[L4](logical-issues.md#l4)** Committed message returns 500 and never fans out — *High*
9. **[S1](security-issues.md#s1)** Setup-token entropy floor — *High*
10. **[S2](security-issues.md#s2)** Recovery token in the URL path — *High*

### Block 3 — release integrity (cheap, and it protects everything above)

11. **[R1](production-readiness.md#r1)** Unify the Go toolchain across CI, release, and container — *High*
12. **[R3](production-readiness.md#r3)** Add `govulncheck` + `audit-rust.sh` CI jobs — *High*
13. **[R2](production-readiness.md#r2)** Make `release-readiness.sh` a positive assertion — *High*

### Block 4 — UI, before anyone sees it

14. **[U1](ui-issues.md#u1)** Raise `outlineVariant` to meet WCAG 1.4.11 — *High, one token*
15. **[U2](ui-issues.md#u2)** + **[U3](ui-issues.md#u3)** + **[U4](ui-issues.md#u4)** First-run connect flow — *High*
16. **[U5](ui-issues.md#u5)** Relative chat-list timestamps — *Medium*
17. **[U6](ui-issues.md#u6)** Master-detail fires in phone landscape — *Medium*
18. **[U7](ui-issues.md#u7)** No scroll-to-new-message affordance — *Medium*

### Block 5 — platform config (blocks finishing I24 on real hardware)

19. **[R13](production-readiness.md#r13)** iOS: `voip`/`audio` background modes, CallKit/PushKit — *High*
20. **[R14](production-readiness.md#r14)** Android: typed foreground service for calls, `POST_NOTIFICATIONS` — *High*
21. **[R15](production-readiness.md#r15)** `NSLocalNetworkUsageDescription` — *Medium*

### Block 6 — performance (do before load, not before launch)

22. **[P1](performance-issues.md#p1)** Blob re-hash on every download — *High*
23. **[P2](performance-issues.md#p2)** `SyncBounds` full history scan per poll — *High*
24. **[P3](performance-issues.md#p3)** Quota `SUM()` scans inside the write transaction — *High*
25. Remaining P4–P11 as capacity work

### Block 7 — everything in `nice-to-haves.md`

Not release-blocking. The high-impact subset is ranked at the top of that file.

## How to read a finding

Every finding uses the same shape:

- **ID + title**
- **Severity** — Critical / High / Medium / Low / Nice-to-have
- **Location** — file and line where it is verifiable
- **Problem** — what the code does
- **Why it matters in production** — the user- or operator-visible consequence
- **Fix** — a specific change, not a direction
- **Blocker** — Yes / No, with the reason
- **Related** — dependencies and knock-on risk

Severity is about production consequence, not code quality. Several **High**
findings sit in otherwise excellent code.
