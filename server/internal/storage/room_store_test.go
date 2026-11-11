package storage

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestRoomCapAndPrune(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	conv, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	for i := 0; i < RoomMaxDevices; i++ {
		if _, err := store.JoinRoom(ctx, conv.ID, owner.Account.ID, fmt.Sprintf("dev_%d", i), now); err != nil {
			t.Fatalf("join %d: %v", i, err)
		}
	}
	if _, err := store.JoinRoom(ctx, conv.ID, owner.Account.ID, "dev_extra", now); !errors.Is(err, ErrRoomFull) {
		t.Fatalf("over cap err=%v", err)
	}
	// A device already in the room can rejoin at the cap.
	if _, err := store.JoinRoom(ctx, conv.ID, owner.Account.ID, "dev_0", now); err != nil {
		t.Fatalf("rejoin at cap: %v", err)
	}
	// Old seats are ended, the empty room ends, and an ended room is deleted later.
	if _, err := store.PruneRooms(ctx, now.Add(13*time.Hour), 12*time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := store.JoinRoom(ctx, conv.ID, owner.Account.ID, "dev_new", now.Add(13*time.Hour)); err != nil {
		t.Fatalf("join after prune: %v", err)
	}
	removed, err := store.PruneRooms(ctx, now.Add(15*time.Hour), 12*time.Hour)
	if err != nil || removed != 1 {
		t.Fatalf("prune removed=%d err=%v", removed, err)
	}
}

func TestRoomSeatEndsWithConversationMembership(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	conv, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	join, err := store.JoinRoom(ctx, conv.ID, owner.Account.ID, "dev_a", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.RoomState(ctx, join.Room.ID, "dev_a"); err != nil {
		t.Fatalf("member state: %v", err)
	}
	// The account is removed from the conversation while it holds a seat.
	if _, err := store.db.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, conv.ID, owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.RoomState(ctx, join.Room.ID, "dev_a"); !errors.Is(err, ErrRoomNotLive) {
		t.Fatalf("state after removal err=%v", err)
	}
	if _, err := store.RoomCommits(ctx, join.Room.ID, "dev_a", 0); !errors.Is(err, ErrRoomNotLive) {
		t.Fatalf("commits after removal err=%v", err)
	}
	if _, err := store.CommitRoom(ctx, join.Room.ID, "dev_a", 0, []byte("commit"), nil, nil, now); !errors.Is(err, ErrRoomNotLive) {
		t.Fatalf("commit after removal err=%v", err)
	}
	if err := store.SetRoomOffer(ctx, join.Room.ID, "dev_a", join.Nonce, []byte("kp"), make([]byte, 64), now.Unix()+30, now); !errors.Is(err, ErrRoomNotLive) {
		t.Fatalf("offer after removal err=%v", err)
	}
	// Leaving still works, and ends the empty room.
	if ended, err := store.LeaveRoom(ctx, join.Room.ID, "dev_a", now); err != nil || !ended {
		t.Fatalf("leave ended=%v err=%v", ended, err)
	}
}
