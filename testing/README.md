# Veritra Test Architecture Audit & Gap Remediation Plan

> **Review status:** These files are proposals, not an authoritative backlog.
> A source-level review found material stale claims, invalid commands, and
> missed gaps. Read [`review_findings.md`](review_findings.md) before using
> them. [`docs/board.md`](../docs/board.md) and
> [`docs/audit-consensus.md`](../docs/audit-consensus.md) remain authoritative.

This directory collects proposed testing-gap audits and remediation ideas for
the Veritra codebase.

The plan is designed strictly around the four Anthropic engineering and multi-agent coordination principles:
1. **[Model Selection](https://claude.com/blog/claude-models-explained-choosing-the-best-model-for-your-use-case)**: Tiered model routing based on reasoning complexity (Strong / Balanced+Advisor / Balanced / Fast).
2. **[Prompt Engineering Best Practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)**: Structured XML contracts, explicit invariants, role conditioning, and unambiguous acceptance criteria.
3. **[Multiagent Orchestration](https://platform.claude.com/docs/en/managed-agents/multiagent-orchestration)**: Domain-specialized test agents, single coordinator synthesis, non-overlapping write sets, and isolated context windows.
4. **[The Advisor Strategy](https://claude.com/blog/the-advisor-strategy)**: High-capability Advisor paired with fast/capable Executors at critical security and protocol checkpoints.

---

## Subsystem Audit & Testing Gap Index

| Subsystem | Audit Document | Focus Areas | Primary Executor Tier |
|---|---|---|---|
| **Crypto Boundary** | [`crypto_testing_gaps.md`](crypto_testing_gaps.md) | OpenMLS 0.8.1, Rust FFI ABI v4, memory sanitizers, RFC 9420 test vectors, state rollback | Strong / Balanced+Advisor |
| **Go Server** | [`server_testing_gaps.md`](server_testing_gaps.md) | Modular monolith, SQLite single-writer, WebSocket stress, auth rate-limiting, blob cleanup, privacy log linter | Balanced+Advisor / Strong |
| **Flutter Mobile** | [`mobile_testing_gaps.md`](mobile_testing_gaps.md) | Drift/SQLite3MC encrypted storage, outbox/sync recovery, UI/Widget tests, background push, accessibility | Balanced+Advisor / Balanced |
| **End-to-End & Infra** | [`e2e_integration_gaps.md`](e2e_integration_gaps.md) | Multi-client MLS simulation, network partitions, TURN/WebRTC relay, positive/negative release gates | Strong / Balanced+Advisor |
| **Traceability Matrix** | [`task_test_traceability_matrix.md`](task_test_traceability_matrix.md) | Complete mapping of 43 tasks (T29-T50, G24, G25, G27) and consensus packages (I29-I50) to test gaps | Coordinator / All Roles |
| **Execution Plan** | [`orchestration_plan.md`](orchestration_plan.md) | Multi-agent orchestration rules, prompt templates, Advisor review checkpoints, execution waves | Coordinator |

---

## Non-Negotiable Invariants for Testing

All test suites and test implementation agents must enforce the core repository boundaries:

1. **Zero Plaintext on Server**: Server tests must verify that message bodies and attachment streams are stored and handled strictly as ciphertext.
2. **Zero Plaintext in Logs**: Automated AST/linter tests must guarantee `log/slog` calls never log message text, request bodies, secrets, tokens, or ciphertext bodies.
3. **Fail-Closed Release Gates**: Incomplete crypto paths (`PM_CRYPTO_UNAVAILABLE`, `UnavailableCryptoService`) must fail closed. Release readiness tests must verify these gates cannot be bypassed.
4. **Generic Push Notifications**: Push payload tests must assert that wake payloads carry only generic markers (`new_encrypted_event_available`) with zero sender identity or message preview data.
5. **Atomic Local State Commit**: Mobile storage tests must verify MLS state, rollback counter, message ciphertext rows, dedupe markers, and sync cursors commit within a single ACID transaction.

---

## Model Tier Allocation Matrix

| Tier | Archetype Model | Testing Responsibilities | Advisor Checkpoint Required? |
|---|---|---|---|
| **Strong** | Claude Opus / High-Reasoning | Crypto protocol vectors, MLS state rollback, security invariant audits, multi-client concurrency models | Yes (Self / Architecture Review) |
| **Balanced + Advisor** | Claude Sonnet + Opus Checkpoints | Complex unit/integration tests (SQLite locks, WebSocket backpressure, Drift encryption, Outbox recovery) | Yes (at architectural and security boundaries) |
| **Balanced** | Claude Sonnet / Fast Coding | Standard unit tests, Widget tests, API contract validations, mock generators, UI component tests | No (Executor owns PR end-to-end) |
| **Fast** | Claude Haiku / Lightweight | Lint checks, test log triage, license notice verification, test vector formatting, fixture generation | No (Mechanical tasks only; no security decisions) |
