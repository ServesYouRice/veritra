# Check C-bbb8fe5d93f3 · stageCommit can leave an orphaned native pending commit when post-stage validation fails

Suggested model: your strongest model (such as Claude Opus), effort high. Why: the audit could not settle this by reading alone.

You are a careful senior engineer checking one reported defect in this repository before anyone fixes it. Several models audited the project; no peer review checked this one, and arbitra's verifier could not decide from the code it was shown. The report may be wrong, so treat it as a claim to test, not a fact.

<claim>
stageCommit can leave an orphaned native pending commit when post-stage validation fails (medium)

Once _groupStageCommit returns OK, the native group holds an unmerged pending commit. stageCommit then runs Dart-side checks that can throw NativeCryptoException(invalidOutput): taking the commit buffer, taking the welcome buffer, and checking that adds and welcome are consistent. On those paths it neither returns the commit nor calls clearPendingCommit. The caller has no bundle to queue as an outbox item, but the native group still carries a staged commit that nothing will complete or abandon.
</claim>

<what_the_verifier_said>
still needs verification: In the binding, stageCommit throws after a successful _groupStageCommit without calling clearPendingCommit, but whether this leaves the group stuck depends on two things the supplied source cannot show: whether the omitted Rust FFI (crypto/rust/src/ffi.rs, mls.rs) can ever return OK with an empty commit or a welcome that does not match adds, and whether the omitted caller (mobile/lib/crypto/native_crypto_service.dart) catches the error or reconciles groupEpoch's pending flag by clearing the commit.
</what_the_verifier_said>

<write_scope>
Change only these files, listed by folder, and test files (named like `a.test.ts`, `test_a.py` or `a_test.go`), which you may also add anywhere. Add other new files only to these folders, not at the repository root, and nothing in a folder or with a name that starts with a dot. arbitra derived them from where the issues are in the code and the modules that hold them, not from the plan's text, so text in the project cannot widen them. Any other change needs the approval of the person you are working with: ask before making it.
- mobile/lib/crypto/: crypto_service.dart, native_crypto_bindings.dart
- mobile/test/: api_contract_test.dart, native_crypto_bindings_test.dart, test_crypto_service.dart
</write_scope>

<steps>
1. Before anything else, run `node .arbitra/plans/2026-10-25-e5546c4c/check-premises.mjs C-bbb8fe5d93f3` from the repository root. It looks up what this prompt names in the code as it is now and prints what moved since the plan was saved (with the new lines), what is gone and what was never found. Work from the code it shows: line numbers below may be stale.
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
