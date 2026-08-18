package storage

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
)

func TestCallAuthorizationRestrictsCreationAndTransitions(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()

	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	peer := registerTestMember(t, ctx, store, invite.Code, "call-peer")
	outsiderInvite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create outsider invite: %v", err)
	}
	outsider := registerTestMember(t, ctx, store, outsiderInvite.Code, "call-outsider")

	group, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind:             "group",
		CreatedBy:        owner.Account.ID,
		MemberAccountIDs: []string{peer.Account.ID},
	})
	if err != nil {
		t.Fatalf("create group: %v", err)
	}
	if _, err := store.CreateCallSession(ctx, group.ID, owner.Account.ID, nil); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("group call err=%v want %v", err, ErrInvalidInput)
	}

	dm, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind:             "dm",
		CreatedBy:        owner.Account.ID,
		MemberAccountIDs: []string{peer.Account.ID},
	})
	if err != nil {
		t.Fatalf("create dm: %v", err)
	}
	if _, err := store.CreateCallSession(ctx, dm.ID, outsider.Account.ID, nil); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider call err=%v want %v", err, ErrNotMember)
	}

	createMetadata := callTestMetadata("create-call")
	call, err := store.CreateCallSession(ctx, dm.ID, owner.Account.ID, createMetadata)
	if err != nil {
		t.Fatalf("create call: %v", err)
	}
	if call.InvitedAccountID != peer.Account.ID || call.Version != 1 || call.State != "ringing" {
		t.Fatalf("call participant/state=%q/%d/%q want peer/1/ringing", call.InvitedAccountID, call.Version, call.State)
	}
	callRetry, err := store.CreateCallSession(ctx, dm.ID, owner.Account.ID, createMetadata)
	if err != nil || callRetry.ID != call.ID {
		t.Fatalf("create retry call=%#v err=%v want original %s", callRetry, err, call.ID)
	}
	changedCreate := json.RawMessage(`{"version":1,"ciphertext":"BA==","protocol":"mls10-openmls-v1","sender_device_id":"device-test","action_id":"create-call"}`)
	if _, err := store.CreateCallSession(ctx, dm.ID, owner.Account.ID, changedCreate); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("changed create retry err=%v want %v", err, ErrIdempotencyConflict)
	}

	answer := callTestMetadata("answer-call")
	active, err := store.TransitionCallSession(ctx, call.ID, peer.Account.ID, 1, "active", answer)
	if err != nil {
		t.Fatalf("answer call: %v", err)
	}
	if active.State != "active" || active.Version != 2 {
		t.Fatalf("active call state/version=%q/%d want active/2", active.State, active.Version)
	}
	answerRetry, err := store.TransitionCallSession(ctx, call.ID, peer.Account.ID, 1, "active", answer)
	if err != nil || answerRetry.Version != 2 || answerRetry.State != "active" {
		t.Fatalf("answer retry call=%#v err=%v want version 2 active", answerRetry, err)
	}
	changedAnswer := json.RawMessage(`{"version":1,"ciphertext":"BA==","protocol":"mls10-openmls-v1","sender_device_id":"device-test","action_id":"answer-call"}`)
	if _, err := store.TransitionCallSession(ctx, call.ID, peer.Account.ID, 1, "active", changedAnswer); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("changed answer retry err=%v want %v", err, ErrIdempotencyConflict)
	}
	if _, err := store.TransitionCallSession(ctx, call.ID, outsider.Account.ID, 2, "ended", nil); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider transition err=%v want %v", err, ErrNotMember)
	}
	if _, err := store.TransitionCallSession(ctx, call.ID, owner.Account.ID, 1, "ended", nil); !errors.Is(err, ErrCallVersion) {
		t.Fatalf("stale transition err=%v want %v", err, ErrCallVersion)
	}

	ended, err := store.TransitionCallSession(ctx, call.ID, owner.Account.ID, 2, "ended", callTestMetadata("end-call"))
	if err != nil {
		t.Fatalf("end call: %v", err)
	}
	if ended.State != "ended" || ended.Version != 3 {
		t.Fatalf("ended call state/version=%q/%d want ended/3", ended.State, ended.Version)
	}
	if _, err := store.TransitionCallSession(ctx, call.ID, peer.Account.ID, 3, "active", nil); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("terminal rewrite err=%v want %v", err, ErrInvalidInput)
	}
}

func callTestMetadata(actionID string) json.RawMessage {
	return json.RawMessage(`{"version":1,"ciphertext":"AQID","protocol":"mls10-openmls-v1","sender_device_id":"device-test","action_id":"` + actionID + `"}`)
}
