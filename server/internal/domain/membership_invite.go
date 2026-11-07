package domain

import "time"

// Membership invitation targets (C1).
const (
	InviteTargetGroup     = "group"
	InviteTargetCommunity = "community"
)

// Join request states.
const (
	JoinRequestPending   = "pending"
	JoinRequestApproved  = "approved"
	JoinRequestRejected  = "rejected"
	JoinRequestCancelled = "cancelled"
)

// MembershipInvite is a link an owner or admin created for a group or a
// community. The server stores only a hash of the locator the creating app
// derived from the link's secret, so it cannot rebuild or show the link.
type MembershipInvite struct {
	ID         string     `json:"id"`
	TargetKind string     `json:"target_kind"`
	TargetID   string     `json:"target_id"`
	CreatedBy  string     `json:"created_by"`
	MaxUses    int        `json:"max_uses"`
	Uses       int        `json:"uses"`
	ExpiresAt  time.Time  `json:"expires_at"`
	CreatedAt  time.Time  `json:"created_at"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty"`
}

// MembershipInvitePreview is what a signed-in holder of a link sees before
// asking to join: the target's name and who invited. It names no member.
type MembershipInvitePreview struct {
	TargetKind      string    `json:"target_kind"`
	TargetName      string    `json:"target_name"`
	InviterUsername string    `json:"inviter_username"`
	ExpiresAt       time.Time `json:"expires_at"`
	AlreadyMember   bool      `json:"already_member"`
}

// JoinRequest is an account's request to join a target through an
// invitation. It grants nothing until an admin approves it.
type JoinRequest struct {
	ID         string     `json:"id"`
	TargetKind string     `json:"target_kind"`
	TargetID   string     `json:"target_id,omitempty"`
	TargetName string     `json:"target_name,omitempty"`
	AccountID  string     `json:"account_id,omitempty"`
	Username   string     `json:"username,omitempty"`
	Status     string     `json:"status"`
	CreatedAt  time.Time  `json:"created_at"`
	DecidedAt  *time.Time `json:"decided_at,omitempty"`
}
