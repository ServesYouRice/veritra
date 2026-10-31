package storage

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestTransitionCallSessionRejectsExpiredCall(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	peer := registerTestMember(t, ctx, store, invite.Code, "call-peer")
	dm, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "dm", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{peer.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	call, err := store.CreateCallSession(ctx, dm.ID, owner.Account.ID, nil)
	if err != nil {
		t.Fatal(err)
	}
	// Live calls keep working.
	other, err := store.CreateCallSession(ctx, dm.ID, owner.Account.ID, callTestMetadata("second-call"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.TransitionCallSession(ctx, other.ID, peer.Account.ID, other.Version, "active", nil); err != nil {
		t.Fatalf("accepting a live call: %v", err)
	}

	if _, err := store.db.ExecContext(ctx, `UPDATE call_sessions SET expires_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Second)), call.ID); err != nil {
		t.Fatal(err)
	}
	events := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events`)
	_, _, err = store.TransitionCallSessionWithSyncEvent(ctx, call.ID, peer.Account.ID, call.Version, "active", nil)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("accepting an expired, unpruned call: err = %v, want %v", err, ErrNotFound)
	}
	var state string
	var version int64
	var expiresAt string
	if err := store.db.QueryRowContext(ctx, `SELECT state, version, expires_at FROM call_sessions WHERE id = ?`, call.ID).Scan(&state, &version, &expiresAt); err != nil {
		t.Fatal(err)
	}
	if state != "ringing" || version != call.Version || !parseTime(expiresAt).Before(time.Now()) {
		t.Fatalf("expired call changed: state=%s version=%d expires_at=%s", state, version, expiresAt)
	}
	if got := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events`); got != events {
		t.Fatalf("sync events %d -> %d, want none for an expired call", events, got)
	}
}
