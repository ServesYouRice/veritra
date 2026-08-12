# Production Readiness — Summary & Fix Order

Verdict: **Not production-ready today — by design** (message crypto is intentionally fail-closed and the repo says so). The foundation is genuinely strong: this audit found the server architecture, privacy boundaries, and deployment hygiene to be well above typical MVP quality. But beyond the documented crypto blocker, the audit found **8 additional must-fix issues**, including one Critical bug (a core endpoint that can never succeed) and one High bug that breaks realtime for the 21st user in the recommended deployment.

## Go / No-Go checklist

### 🔴 Blockers (must fix before launch)

| # | Finding | File | Effort |
|---|---|---|---|
| 0 | Mobile MLS crypto integration (documented) | `REMAINING-WORK.md` | Large |
| 1 | L-1: `conversation_members` table doesn't exist — key-package claim always 500s | logical-issues.md | Minutes + test |
| 2 | S-1: tokenless owner setup spoofable behind same-host proxy | security-issues.md | Small |
| 3 | L-2: WS per-IP cap counts the proxy — realtime capped at 20 devices | logical-issues.md | Small |
| 4 | D-1/D-2: reference deployments missing `ENV=production` + setup token | deployment-risks.md | Minutes |
| 5 | L-4/UI-9: DMs silently convertible to groups | logical-issues.md | Small |
| 6 | L-5: backup/attachment downloads killed at 30 s | logical-issues.md | Small |
| 7 | L-3/P-6: mobile secure-storage races + size limits (one refactor) | logical-issues.md | Medium |
| 8 | L-12: no leave/kick/member-list endpoints | logical-issues.md | Medium |
| 9 | L-13: members have no password recovery | logical-issues.md | Medium |
| 10 | UI-1: DMs indistinguishable (no counterpart identity) | ui-issues.md | Medium |
| 11 | UI-5: no message-history pagination in chat | ui-issues.md | Small |
| 12 | UI-13: block/unblock unreachable from the UI | ui-issues.md | Small |
| 13 | D-3/D-8: backup automation + production runbook | deployment-risks.md | Small–Medium |
| 14 | T-1/T-2: key-package tests + schema-touch test | testing-gaps.md | Small |
| 15 | Independent security review incl. WS parser fuzzing (S-2) | security-issues.md | External |

### 🟡 Fix before or shortly after launch

- L-6 scoped busy/error state; L-7 poison-outbox handling; L-11 `GET /messages/{id}`; L-8 shared-attachment prune; S-3 per-account login throttling + enrollment rate class (L-15); S-4 audit-log privacy trim; S-5 crypto-protocol allow-list; P-1 unread-count query; P-2 incremental catch-up; UI-4 delete-message UI; UI-10 notification honesty; UI-14 manual a11y pass; D-4 startup exclusivity lock; T-3/T-4/T-6/T-9 tests.

### 🟢 Verified healthy (no action)

- Auth flow design (bcrypt + device secret + hashed tokens + timing equalization + recent-auth gate)
- Enrollment protocol (challenge binding, atomic reservation consumption, replay-safe)
- Ciphertext-only persistence, plaintext-key tripwires, privacy-safe logging (route classes, no bodies)
- Idempotent message writes with envelope+event in one transaction
- Migration engine (checksummed, transactional), backup/restore CLI design (manifest + rollback)
- Retention sweeps (paginated, clock-injectable), storage quotas, push SSRF hardening
- Container/CI supply-chain hygiene (pinned digests/SHAs, scratch non-root, provenance, license gate)
- Client empty/loading/error states, semantics work, fail-closed crypto UX

## Recommended fix order

**Wave 1 — same-day fixes (before any other work):**
1. L-1 table name (+ T-1 test, + T-2 schema-touch test so the class is dead)
2. D-1/D-2 deployment env lines
3. S-1 fail-closed setup token in production
4. L-4 DM kind check (+ hide UI affordance)
5. L-5 download deadline prefixes
6. UI-3 mojibake

**Wave 2 — architecture-adjacent (do before MLS orchestration is built on top):**
7. L-2 hub client-IP resolution
8. L-12 membership removal API design (MLS-removal hook shape)
9. L-3 + P-6 mobile storage refactor (encrypted DB + serialized access)
10. S-5 protocol allow-list; L-11 single-message GET
11. T-3/T-4 proxy + WS-parser tests

**Wave 3 — product completeness (parallel with MLS work):**
12. UI-1 identity in conversation list; UI-5 pagination; UI-13 blocks UI; L-13 member recovery; UI-10 notifications honesty; L-6/L-7 client error/outbox hygiene

**Wave 4 — launch operations:**
13. D-3 backup timer + D-8 runbook; P-1/P-2 hot-path tuning; S-3 throttling; a11y pass; independent security review (last, over the finished crypto path)

## One-paragraph summary

Veritra's server is a carefully built, privacy-honest foundation whose main risk is not sloppiness but *unexercised surface*: the two worst bugs (a query against a nonexistent table, and a connection cap that counts the reverse proxy) live exactly where no test and no real deployment has ever pushed. Fix Wave 1 in a day, build the schema-touch and proxy-topology tests so those bug classes stay dead, land the mobile storage refactor before the MLS work multiplies local state, and the remaining path to production is the one the repo already documents: wire the crypto, then let an external reviewer at it.
