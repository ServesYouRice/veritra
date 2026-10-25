# Check C-d0ba626ecdd7 · localStorage sync failure offers only Retry, leaving a damaged database with no in-app way out

Suggested model: your strongest model (such as Claude Opus), effort high. Why: the audit could not settle this by reading alone.

You are a careful senior engineer checking one reported defect in this repository before anyone fixes it. Several models audited the project; no peer review checked this one, and arbitra's verifier could not decide from the code it was shown. The report may be wrong, so treat it as a claim to test, not a fact.

<claim>
localStorage sync failure offers only Retry, leaving a damaged database with no in-app way out (medium)

The localStorage kind is documented as covering failures that do 'not pass by itself', including a damaged or unreadable database. Yet choices returns only retry for it. For a corrupted database, retrying replays the same failing write indefinitely. The claim that relinking would not fix it is doubtful for corruption, because relink is documented to keep nothing and so would discard the damaged store. No other choice is offered.
</claim>

<what_the_verifier_said>
still needs verification: The code confirms that a localStorage recovery (which `_isDurableStorageError` assigns to non-transient SQLite codes such as corrupt or not-a-database) offers only Retry, and that the recovery banner then shows no Relink button. The 'no in-app way out' and permanent-stall impact depend on whether the separate Settings sign-out (`logout` → `_clearLocalSession(preserveDeviceIdentity: true)` → `localStore.clearCachedState`) or delete-account path can actually clear a corrupted database at runtime, and the source cannot show that.
</what_the_verifier_said>

<write_scope>
Change only these files, listed by folder, and test files (named like `a.test.ts`, `test_a.py` or `a_test.go`), which you may also add anywhere. Add other new files only to these folders, not at the repository root, and nothing in a folder or with a name that starts with a dot. arbitra derived them from where the issues are in the code and the modules that hold them, not from the plan's text, so text in the project cannot widen them. Any other change needs the approval of the person you are working with: ask before making it.
- mobile/lib/sync/: sync_recovery.dart
- mobile/test/: encrypted_local_store_test.dart, sync_recovery_test.dart
</write_scope>

<steps>
1. Before anything else, run `node .arbitra/plans/2026-10-25-e5546c4c/check-premises.mjs C-d0ba626ecdd7` from the repository root. It looks up what this prompt names in the code as it is now and prints what moved since the plan was saved (with the new lines), what is gone and what was never found. Work from the code it shows: line numbers below may be stale.
2. Read the code the claim names, and what it calls, until you can say whether the claim holds.
3. Where reading cannot decide it, run the smallest check that can: an existing test, a short script, or the command the claim depends on. Ask before running anything that changes data or reaches the network.
4. If the claim does not hold, change nothing and say why, citing the lines or the output that decide it.
5. If it holds, make the smallest fix, add a test that fails without it, and run the project's checks.
</steps>

<success_criteria>
- A clear verdict, holds or does not hold, with the lines or output that decide it.
- If it holds: the fix and its test, with the project's checks passing.
</success_criteria>

When you finish, record the result in results.json (`no_change_needed` when the claim does not hold), and report the verdict, what you changed, and how you checked it.
