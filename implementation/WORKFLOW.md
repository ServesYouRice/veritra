# LLM execution and orchestration workflow

This workflow follows Anthropic's current guidance while remaining usable by
Codex, Claude, or another capable coding agent:

- [Model selection](https://claude.com/blog/claude-models-explained-choosing-the-best-model-for-your-use-case)
- [Prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)
- [Multiagent orchestration](https://platform.claude.com/docs/en/managed-agents/multiagent-orchestration)
- [Advisor strategy](https://claude.com/blog/the-advisor-strategy)

## Roles

### Coordinator

One coordinator chooses tasks, checks dependencies and write-set overlap,
integrates results, runs final checks, and alone updates `docs/board.md` and
`docs/audit-consensus.md`. The coordinator never delegates two tasks that can
edit the same files concurrently.

### Executor

An executor owns one task end to end: verify, plan, implement, test, and report.
It may not expand scope, weaken a release gate, or silently reinterpret an
acceptance criterion. Advice does not transfer ownership; the executor remains
responsible for the patch.

### Advisor

The advisor is a stronger model consulted for a bounded question. Use it at the
checkpoints named by the task, especially for security, MLS ordering,
migrations, credential lifecycle, platform policy, or a failed second design.
Send only the relevant invariant, evidence, proposed design and disputed
choice. Ask for risks, counterexamples and missing tests—not a replacement
implementation.

## Model selection

Start with the strongest generally available model until repository-specific
evaluations show a lower tier reliably clears the task. Match capability to
reasoning difficulty rather than programming language.

- **Strong:** strongest available reasoning/coding model; use directly for
  protocol, security-boundary, migration, recovery and release-gate tasks.
- **Balanced+advisor:** capable general coding model (for example Sonnet-class)
  with a Strong advisor at named checkpoints. This is the default for bounded
  implementation work.
- **Balanced:** capable general coding model without mandatory advice; suitable
  for isolated UI, tests and measured optimizations with explicit contracts.
- **Fast:** use only for mechanical, read-only inventory or formatting after an
  evaluation proves reliability. A Fast agent never owns a security decision.

Do not hard-code a model version into a task. Model availability changes; the
capability bar and checks are the durable requirement.

## Context packet

Each executor receives only:

1. `AGENTS.md` and this workflow.
2. One task file.
3. The named consensus and source-audit sections.
4. The task's starting code paths and relevant test files.
5. Any coordinator note about overlapping uncommitted work.

Do not load all audits or `docs/archive/`. For a long-context handoff, place
source material before the request and put the explicit assignment last.

Use this prompt shape when the harness benefits from structured instructions:

```xml
<role>You are the executor for exactly one Veritra task.</role>
<context>Read the attached task contract and named source sections.</context>
<invariants>Preserve every privacy and fail-closed boundary in AGENTS.md.</invariants>
<instructions>
1. Confirm the finding against current code.
2. State the smallest design and affected files.
3. Consult the advisor if the task requires it.
4. Implement only this task and run every named check.
5. Return the handoff format from the task.
</instructions>
<task>implementation/tasks/TXX-name.md</task>
```

## Claim and execution protocol

1. Check `docs/board.md`; a task file's “initial eligibility” is historical.
2. Verify every dependency is complete and no other active task owns an
   overlapping write set.
3. Mark the source card claimed on the board before product edits.
4. Reproduce or prove the defect. If it is stale, stop and report evidence.
5. Write a short plan tied directly to acceptance checks.
6. Use an advisor only at named checkpoints or after two failed approaches.
7. Implement the smallest complete change. Preserve unrelated user work.
8. Run narrow checks first, then the task's integration checks.
9. Review the final diff against invariants and acceptance criteria.
10. The coordinator updates the board/consensus and binds evidence to the
    actual commit.

## Parallel-agent rules

Parallelize independent tasks across different surfaces; specialize agents by
domain. Every agent has isolated conversational context even when sharing a
filesystem, so assignments must be self-contained.

- Safe example: T43A theme tokens and T42A server call authorization, after
  confirming their tests do not share generated files.
- Unsafe example: T30B and T32 both changing `mobile/lib/core/app_state.dart`.
- Unsafe example: T36A and T36B concurrently changing message commit/fanout
  interfaces.
- One coordinator synthesizes reports and resolves integration failures.
- Do not create nested agent teams. Escalate one bounded question to one
  advisor instead.

## Required handoff

Every executor returns:

```text
Task: TXX
Result: complete | stale | blocked
Confirmed cause: <one sentence with code path>
Changed files: <paths>
Checks: <command and result>
Acceptance: <each criterion pass/fail>
Security/privacy review: <what was checked>
Residual blockers: <none or exact blocker>
Advisor: <not required, or question + adopted/rejected advice>
```

“Complete” means all acceptance criteria and required checks pass. A partial
patch is not complete. Never hide skipped tests or substitute inspection for a
required real-device/external gate.

## Stop and escalate

Stop before editing when the task requires a product/protocol choice not made
in the consensus, a new dependency, schema-destructive migration, credential,
external deployment, release publication, or weakened privacy/crypto boundary.
Report the exact decision needed. Do not invent authority.

