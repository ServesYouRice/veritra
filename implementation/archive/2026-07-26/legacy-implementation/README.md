# Lower-model implementation playbook

This folder converts the merged audit into small, ordered implementation
tasks. Give a lower-capability model this file plus exactly one task card.
Do not give it every plan at once.

The structure follows Anthropic's prompting guidance:

- state the role, context, output, and constraints explicitly
- explain why security and ordering constraints matter
- use numbered steps when completeness matters
- separate context, task, constraints, acceptance criteria, and output
- require inspection before claims or edits
- require a self-check against concrete tests
- keep long work incremental and persist status in a structured file

Reference:
https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices

## Plan order

1. [00-baseline.md](00-baseline.md)
2. [01-server-invariants.md](01-server-invariants.md)
3. [02-sync-consistency.md](02-sync-consistency.md)
4. [03-mobile-storage-and-crypto.md](03-mobile-storage-and-crypto.md)
5. [04-membership-and-safety.md](04-membership-and-safety.md)
6. [05-mobile-ux.md](05-mobile-ux.md)
7. [06-deployment-and-recovery.md](06-deployment-and-recovery.md)
8. [07-performance.md](07-performance.md)
9. [08-verification.md](08-verification.md)
10. [09-deferred-roadmap.md](09-deferred-roadmap.md)

Machine-readable task state lives in [tasks.json](tasks.json). A model may
change only its assigned task from pending to in_progress, blocked, or
complete. It may use complete only after the stated acceptance criteria pass.

## Prompt assembly

Put repository context first, then the selected task card, then end with the
request. Use this wrapper:

    <role>
    You are implementing one bounded task in Veritra, a privacy-first
    self-hosted messenger.
    </role>

    <repository_context>
    Repository root: C:\Users\V\Documents\Veritra\Veritra
    Read AGENTS.md first. Read only the files named by the task card plus files
    directly required to understand their interfaces.
    </repository_context>

    <task_card>
    Paste exactly one task card here.
    </task_card>

    <global_constraints>
    Preserve ciphertext-only server boundaries. Never log or persist plaintext
    message or attachment contents. Do not add telemetry. Do not weaken a test
    or release gate to make it pass. Do not add dependencies without license
    review and THIRD_PARTY_NOTICES.md. Do not modify unrelated files.
    </global_constraints>

    <required_workflow>
    1. Inspect every named file before making claims.
    2. Confirm the defect still exists.
    3. Add or update the narrow regression test first when the card requests it.
    4. Make the smallest complete implementation.
    5. Run the exact verification commands.
    6. Review the diff for privacy, scope, and accidental generated files.
    7. Update only this task's entry in implementation/tasks.json.
    </required_workflow>

    <final_request>
    Implement this task now. Stop and report evidence if the premise is false
    or a required dependency/design decision is missing. Finish with changed
    files, tests run, results, and remaining risks.
    </final_request>

## Behavior examples

Use these as outcome examples, not text to copy literally:

    <example>
    Premise is stale: migration 0007 already enforces the requested invariant.
    No production edit made. Task remains pending; evidence: file and line.
    </example>

    <example>
    Blocked: the card requires a protocol identifier that the approved design
    does not define. Task marked blocked. No substitute identifier invented.
    </example>

    <example>
    Complete: narrow regression failed before the fix and passed after it;
    canonical scoped test and diff review also passed. Task marked complete.
    </example>

## Rules for task authors and reviewers

- One task should normally touch one subsystem and no more than three to five
  production files.
- Split a task again if it needs independent protocol, product, or dependency
  decisions.
- Tests define acceptance, not the implementation. Reject hardcoded
  test-specific workarounds.
- Performance cards begin with measurement. They do not authorize speculative
  denormalization or new infrastructure.
- Crypto cards fail closed. Never replace UnavailableCryptoService until the
  complete release evidence in C13 passes.
- External actions, destructive operations, dependency additions, and release
  publication require explicit approval.
- If verification cannot run, leave the task incomplete and record the exact
  blocker. Static inspection is not a passing test result.

## Status values

- pending: not started
- in_progress: being implemented; acceptance criteria not yet satisfied
- blocked: requires an explicit design, dependency, platform, or external
  review decision
- complete: all listed verification passed and the diff was reviewed
