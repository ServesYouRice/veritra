package domain

import "time"

// C4 server succession (docs/designs/C4-custom-roles.md, "Server
// succession"). Apps decide ownership from the group's signed role record
// and never read the server's owner row (D80); the server cannot read that
// record (commits are MLS ciphertext). So when an election is won in the
// record, the server's row follows only by its own rule, which every honest
// win meets and an active owner always blocks:
//
//   - the owner has been quiet in the scope, by the server's clock, for at
//     least OwnerSuccessionQuiet (D81's 30 days before an election opens plus
//     its 7-day vote wait), and
//   - more than half of the scope's current admins (the owner excluded) have
//     asked, since the owner was last active, for the same candidate, who is
//     one of them; with no admin, only the longest-serving member may ask,
//     and only for itself (D81's no-admin claim).
//
// Activity is kept per UTC day (L2-2), so a day counts as active to its end.

// OwnerSuccessionQuiet is how long the owner must have been quiet.
const OwnerSuccessionQuiet = 37 * 24 * time.Hour

// ActivityDay is the UTC day an activity at t is recorded under.
func ActivityDay(t time.Time) time.Time {
	t = t.UTC()
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
}

// ActivityEnd is the first instant after the recorded activity day lastDay.
// Asks must be made at or after it, and the quiet wait starts there.
func ActivityEnd(lastDay time.Time) time.Time {
	return ActivityDay(lastDay).Add(24 * time.Hour)
}

// OwnerQuiet reports whether an owner last active on lastDay has been quiet
// long enough at now. A nil lastDay (no owner row, or no activity known)
// is quiet.
func OwnerQuiet(lastDay *time.Time, now time.Time) bool {
	if lastDay == nil {
		return true
	}
	return !now.Before(ActivityEnd(*lastDay).Add(OwnerSuccessionQuiet))
}

// SuccessionQuorum reports whether asks from more than half of eligible
// accounts were counted.
func SuccessionQuorum(asks, eligible int) bool {
	return eligible > 0 && asks*2 > eligible
}
