package domain

import "time"

// Moderation rules (C5). Pure functions over the built-in roles, so the
// server and tests share one definition. Custom roles (C4) will replace the
// role arguments with permission checks; see docs/designs/C5-moderation.md.

const (
	// MaxTimeout bounds one timeout, so a mistaken or hostile one expires.
	MaxTimeout = 28 * 24 * time.Hour
	// MaxSlowMode bounds the per-member gap between posts in a channel.
	MaxSlowMode = 6 * time.Hour
)

// CanModerate reports whether actor may kick, ban or time out target: the
// actor must be a moderator or above and outrank the target. Nobody
// moderates themselves (leaving is a separate action).
func CanModerate(actorRole, targetRole string, sameAccount bool) bool {
	if sameAccount || !CanManageMembers(actorRole) {
		return false
	}
	return RoleRank(targetRole) > 0 && RoleRank(targetRole) < RoleRank(actorRole)
}

// CanDeleteOthersMessage reports whether actor may delete a message that a
// sender with senderRole posted. It is the same rule as moderating the sender.
func CanDeleteOthersMessage(actorRole, senderRole string) bool {
	return CanModerate(actorRole, senderRole, false)
}

// ValidTimeout reports whether d is an allowed timeout length.
func ValidTimeout(d time.Duration) bool { return d > 0 && d <= MaxTimeout }

// ValidSlowMode reports whether d is an allowed slow-mode gap (0 turns it off).
func ValidSlowMode(d time.Duration) bool { return d >= 0 && d <= MaxSlowMode }

// TimedOut reports whether a member with the given timeout end is muted now.
// A nil end means no timeout.
func TimedOut(until *time.Time, now time.Time) bool {
	return until != nil && now.Before(*until)
}

// SlowModeWait is how long the sender must still wait before posting.
// Moderators and above are exempt, as is a channel with no slow mode or a
// first post.
func SlowModeWait(role string, gap time.Duration, lastPost *time.Time, now time.Time) time.Duration {
	if gap <= 0 || lastPost == nil || CanManageMembers(role) {
		return 0
	}
	if wait := lastPost.Add(gap).Sub(now); wait > 0 {
		return wait
	}
	return 0
}
