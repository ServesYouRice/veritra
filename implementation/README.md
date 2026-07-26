# Implementation

This is the only active work system. Start at [KANBAN.md](KANBAN.md), then give
an executor exactly one linked card. Historical audits and plans are read-only
under `archive/`.

## Executor prompt

Replace `I01` with one Ready card ID.

```xml
<role>
You are the implementation executor for one bounded Veritra task.
</role>

<context>
Read AGENTS.md, implementation/KANBAN.md, and the I01 task card.
Read only files named by the card or directly required by their interfaces.
Do not read implementation/archive unless the card links a specific file.
</context>

<workflow>
1. Confirm the problem still exists. If stale, report evidence and update the board.
2. Mark only I01 as Doing.
3. Add the narrow regression test first when the card requests one.
4. Implement the smallest complete fix. Do not change unrelated files.
5. Run every verification command available in the environment.
6. Review the diff for privacy, security, and scope.
7. Move I01 to Done only when its completion checks pass; otherwise move it to Blocked with one short reason.
</workflow>

<request>
Implement I01 now. Finish with at most five bullets: result, files, tests, and any blocker or risk.
</request>
```

## Board rules

- `Ready`: dependencies satisfied; safe to claim.
- `Doing`: actively owned. Keep this small.
- `Blocked`: include one reason or decision ID.
- `Backlog`: ordered, but not ready yet.
- `Done`: checks passed; include the date.
- Only the user resolves `D` decision items.

Do not create new audit or plan files. Add a small card only when new work is
confirmed and not already represented.

## Sources used

The task format uses Anthropic's guidance on direct prompts, explicit output,
XML sections, bounded context, progressive disclosure, state tracking, advisor
escalation, and independent parallel work:

- https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models
- https://claude.com/blog/the-advisor-strategy
- https://platform.claude.com/docs/en/managed-agents/multiagent-orchestration

## Archive

`archive/2026-07-26/` preserves the two audits, original brief, old remaining
work tracker, architecture docs/ADRs, and the superseded 90-card plan.
