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
