# C2 receiver seam (2026-11-07)

Apps cannot drop restricted posts on today's data (no verified role without
C4's record, owner rule D80). Built: the pure drop rule, its call in the
receive path behind a `VerifiedRoleSource` interface nothing implements yet
(a dropped post leaves a hidden action row; no notice, no text, state and
cursor commit), and a native test with a fake source (no record: kept; member
under a restricting record: dropped; same sender as admin: kept).
Not done: C7's channel-less exemption on the server (needs C0's change, see
the design), composer hiding, the epoch question (current record vs record at
the message's epoch: C4 decides).

Checks: `flutter analyze`, `dart format`, `flutter test
test/posting_verdict_test.dart test/native_outbox_test.dart` (native library
set). Opus review: three blockers fixed (bundled reformat removed, dropped
post row, wrong exemption removed).
