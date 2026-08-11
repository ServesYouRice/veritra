# implementation

Critique of `audits-codex/` measured against `audits-opus/`, with every
contested claim re-checked against the working tree on 2026-08-11.

> `AGENTS.md` says documentation lives in `docs/`. This folder was created at
> explicit user instruction. If adopted, its long-term home is `docs/`.

## Verdict in one paragraph

Codex found one genuine Critical that the opus audit missed entirely
(**background push advances the sync cursor without processing MLS**), plus four
concrete server/client defects the opus audit also missed. The opus audit found
seven defects codex missed, including one blocker (**setup token has no entropy
floor**) and one fail-open security bug in a file codex reviewed. Codex is
weakest where it describes process gaps instead of defects: its UI and testing
chapters are largely "no evidence exists", and it missed the one accessibility
failure that is computable from source. Two codex claims are factually wrong and
would waste work if implemented as written.

**Net: 5 codex findings to adopt, 2 to correct before acting, 7 opus findings
codex missed, and 2 opus findings this pass downgraded on re-verification.**

## Files

| File | What it is |
| --- | --- |
| [critique.md](critique.md) | Finding-by-finding: confirmed, overstated, wrong, missed |
| [plan.md](plan.md) | The merged blocker list and the order to build it in |

## The reconciled blocker list

Nine items. Everything else is post-launch.

| # | Blocker | Source | Verified |
| --- | --- | --- | --- |
| 1 | Background catch-up advances cursor without MLS processing | codex LOG-01 | ✅ |
| 2 | Outbox silently evicts the oldest unsent message at 100 | both | ✅ |
| 3 | Recovery capability written verbatim to the request log | both | ✅ |
| 4 | Poison sync event wedges catch-up permanently | opus L2 | ✅ |
| 5 | MLS outbox has no error handling; head-of-line blocks forever | both | ✅ |
| 6 | `resetOnError: true` destroys the local database key | both | ✅ |
| 7 | Expired-content sweeper cannot drain its backlog | both | ✅ |
| 8 | Setup token has no entropy floor | opus S1 | ✅ |
| 9 | Account export leaks live push `auth_secret` | codex SEC-02 | ✅ |

Items 1, 9 are codex-only. Items 4, 8 are opus-only. The rest are joint.
