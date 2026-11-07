# Demo e2e: "timed out waiting for sync after 240 s"

2026-11-07. Job logs read with the GitHub API for runs of `ci.yml`.

## What failed

Every failure of the step "Test the demo message flow with real clients"
(Linux `mobile` job) and "Run the demo flow ..." (Windows `desktop-windows`
job) is the same line, from `mobile/test/demo_e2e_test.dart` line 259 (the
wait for the restored, re-linked device to get a group epoch for the owner/alice
DM), after the full 240 s, with "connection online, error none":

| Job id | Branch | OS |
| --- | --- | --- |
| 128350411749 | agent/c6-review-fixes | Linux |
| 128350640151 | agent/c1-scoped-sync-routes | Linux |
| 128364177251 | agent/k2-review-ci | Linux |
| 128374459664 | agent/c4-handover-rules | Linux |
| 128351557849 | agent/k0r-push-wake | Windows |
| 128367604037 | agent/c4-handover-rules | Windows |
| 128374459726 | agent/c4-handover-rules | Windows |
| 127964346293 | agent/c1-scoped-sync-routes | Windows |

Same commit, same code, both outcomes: for example `agent/c4-handover-rules`
at 09:36 passed on Linux and failed on Windows; `agent/k0r-push-wake` passed
on Linux and failed on Windows in one run. In passing runs the whole test
takes 6 to 8 s (for example jobs 128353251870, 128352413909, 128351557808,
128350990571, 128367604056). There is no slow middle: it is either 7 s or
the full 240 s. So the wait is not legitimately slow, and raising it
would not help.

The other red CI jobs seen on 2026-11-07 are not this: runs from 08:56 to
09:43 failed at `flutter pub get` (window_manager 0.6.0 needs Dart 3.13, reverted
in #119).

## Cause

For a group the server names the coordinator of a change: the group device with
the lowest id (`MIN(device_id)`, `server/internal/storage/mls_group_store.go`).
In the DM the group devices are the owner's and alice's, and device ids are
random, so each run picks one of them at random.

- Owner is the coordinator: the owner gets the `device.updated` event for the
  link, runs reconcile, and adds the new device. About 7 s.
- Alice is the coordinator: the `device.updated` event is scoped to the owner's
  account, so alice's device never sees it and never runs a pass. The owner's
  device is a non-coordinator and records the change as first seen, then is meant to
  step in after `_reconcileFallback` (3 minutes). But the fallback was only
  checked when some catch-up happened to run, and nothing starts one: no event
  arrives, there is no periodic poll, and `_armMlsRetryWake` only listed
  failure backoffs. The test sends nothing in between, so the fallback never
  ran and the wait timed out.

This is a product bug, not only a test bug: in a quiet chat, a device linked by
the other side's account is never added to the group.

## Fix

`mobile/lib/core/app_state.dart`: the wake that `_armMlsRetryWake` arms now also
covers `firstSeen + fallback` of each change still pending, so a pass runs when
the fallback ends. The fallback is `reconcileFallback` (`@visibleForTesting`,
3 minutes by default). Unit test: `mobile/test/mls_reconcile_fallback_test.dart`.

The e2e now prints which device coordinated and how long the join took, so
CI logs show which path a run took. The wait stays at 4 minutes: the fallback
path needs about 3 minutes plus a pass.

Not changed here, for review: telling the coordinator promptly when a
co-member links a device would need a new server event (an MLS-ordering and
sync-contract change), so the half of runs where alice coordinates still waits
about 3 minutes.

Checks: Dart is not installed locally, so the unit test and the e2e run in
GitHub CI on the pull request.
