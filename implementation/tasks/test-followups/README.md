# Confirmed testing follow-ups

These are small executor contracts derived from the source review at
`testing/review_findings.md`. They are supplemental children of the canonical
tasks named below; they do not create new product authority or change status.

Before assigning one, the coordinator must recheck the current `HEAD`, confirm
the parent is eligible in `docs/board.md`, claim that parent, and check the
allowed write set against other work. Give an executor only `AGENTS.md`,
`implementation/WORKFLOW.md`, this index, one QA contract, and its named code.

| ID | Canonical owner | Current routing | Executor | Contract |
|---|---|---|---|---|
| QA01 | T40C/T40D | Ready for coordinator claim as I40 checks follow-up | Balanced+advisor | [Run and extend release-policy fixtures](QA01-release-policy-fixtures.md) |
| QA02 | T40C/G24 | Design checkpoint ready; code blocked until schema approval | Balanced+advisor | [Separate simulator and signed-iOS evidence](QA02-ios-evidence-semantics.md) |
| QA03 | T42A/T42B | Ready as T42A contract verification; no native T42B work | Balanced+advisor | [Repair the mobile/server call contract](QA03-call-contract.md) |
| QA04 | I17/G24 | Prepared; coordinator must add a canonical board child before claim | Balanced+advisor | [Test the attachment crypto pipeline](QA04-attachment-crypto-pipeline.md) |
| QA05 | T45C | Blocked by I29, I39, and T45A | Balanced+advisor | [Test the mobile backup crypto pipeline](QA05-backup-crypto-pipeline.md) |
| QA06 | T41 | Blocked until I41 is eligible | Balanced+advisor | [Test server push providers](QA06-push-provider-contracts.md) |
| QA07 | T41 | Blocked until I41 is eligible | Balanced+advisor | [Test durable push delivery outcomes](QA07-push-worker-outcomes.md) |
| QA08 | T41 | Blocked until I41 is eligible | Balanced | [Test the Flutter push bridge](QA08-mobile-push-bridge.md) |
| QA09 | T45A | Blocked by I29 and I39 | Balanced+advisor | [Test historical upgrades and migration rollback](QA09-migration-upgrade-fixtures.md) |
| QA10 | T40D/T47 | Measurement may start; enforcement needs advisor approval | Balanced+advisor | [Create a coverage baseline and ratchet](QA10-coverage-baseline.md) |

## Assignment rules

- One executor owns one QA contract end to end.
- `Initial eligibility` is a snapshot, not permission. The board wins.
- A lower-tier executor never makes a release, crypto, recovery, migration, or
  platform-policy decision. It stops at the named advisor checkpoint.
- No task may add a dependency, weaken `PM_CRYPTO_UNAVAILABLE`, enable
  crypto-gated UI, add contentful push, or log secrets/ciphertext.
- `stale` is a valid result: if the confirmation command no longer proves the
  gap, make no edits and return the evidence.
- Do not run QA01, QA02, and QA10 concurrently; their workflow/script write
  sets can overlap. Do not run QA04 and QA05 concurrently.

## Executor prompt

```text
You own exactly one Veritra QA follow-up. Read AGENTS.md,
implementation/WORKFLOW.md, and the assigned contract. Confirm the gap before
editing. Stay inside the allowed write set. Stop on every blocker or advisor
checkpoint. Run every required check and return the contract handoff exactly;
never call inspection a passing runtime check.
```

