package storage

import (
	"context"
	"errors"
	"testing"
)

// TASK-209: the account stream's opt-in bounded scan. A blocked sender's run
// after the cursor is crossed once; a cursor at the reported position is
// accepted even though it names a hidden row.
func TestSyncPageBoundedCrossesHiddenTailOnce(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	old := scopedSyncScanBudget
	scopedSyncScanBudget = 3
	t.Cleanup(func() { scopedSyncScanBudget = old })
	who := f.blocker
	start := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	var hidden []int64
	for i := 0; i < 8; i++ {
		_, id := f.send(t, ctx, "bt"+string(rune('a'+i)), nil)
		hidden = append(hidden, id)
	}

	// Unbounded: nothing visible, and the whole tail is scanned again by
	// the next poll (the defect); the position is the scan end.
	legacy, err := f.store.ListSyncPage(ctx, who.Account.ID, who.Device.ID, start, 100, false)
	if err != nil || len(legacy.Events) != 0 || legacy.Truncated {
		t.Fatalf("legacy page = %+v, %v", legacy, err)
	}

	cursor := start
	pages := 0
	for {
		page, err := f.store.ListSyncPage(ctx, who.Account.ID, who.Device.ID, cursor, 100, true)
		if err != nil {
			t.Fatalf("page from %d: %v", cursor, err)
		}
		pages++
		if len(page.Events) != 0 {
			t.Fatalf("hidden run returned events %v", pageEventIDs(page.Events))
		}
		if page.ScannedThrough < cursor || (page.Truncated && page.ScannedThrough <= cursor) {
			t.Fatalf("cursor %d did not advance: %d", cursor, page.ScannedThrough)
		}
		cursor = page.ScannedThrough
		if !page.Truncated {
			break
		}
		if pages > 10 {
			t.Fatal("did not terminate")
		}
	}
	if pages != 3 || cursor != hidden[len(hidden)-1] {
		t.Fatalf("pages = %d, cursor = %d, want 3 pages through %d", pages, cursor, hidden[len(hidden)-1])
	}
	// The cursor is now past the tail: a poll scans nothing.
	again, err := f.store.ListSyncPage(ctx, who.Account.ID, who.Device.ID, cursor, 100, true)
	if err != nil || again.Truncated || len(again.Events) != 0 || again.ScannedThrough != cursor {
		t.Fatalf("poll after the tail = %+v, %v", again, err)
	}
	// A later visible event is delivered from that cursor.
	visibleID := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	next, err := f.store.ListSyncPage(ctx, who.Account.ID, who.Device.ID, cursor, 100, true)
	if err != nil || len(next.Events) != 1 || next.Events[0].ID != visibleID {
		t.Fatalf("visible after tail = %v, %v", pageEventIDs(next.Events), err)
	}
}

// VAL-306: a hidden-row cursor is not expired in bounded mode, also when the
// prune marks do not cover it (pre-0044 ids take the legacy row test); a
// cursor behind a pruned prefix still is.
func TestSyncPageBoundedExpiry(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	who := f.blocker
	var hidden []int64
	for i := 0; i < 6; i++ {
		_, id := f.send(t, ctx, "ex"+string(rune('a'+i)), nil)
		hidden = append(hidden, id)
	}
	visibleID := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	if _, err := f.store.db.ExecContext(ctx, `DELETE FROM sync_prune_state`); err != nil {
		t.Fatal(err)
	}
	page, err := f.store.ListSyncPage(ctx, who.Account.ID, who.Device.ID, hidden[3], 100, true)
	if err != nil || len(page.Events) != 1 || page.Events[0].ID != visibleID {
		t.Fatalf("bounded from hidden row = %v, %v", pageEventIDs(page.Events), err)
	}
	if _, err := f.store.ListSyncPage(ctx, who.Account.ID, who.Device.ID, hidden[3], 100, false); !errors.Is(err, ErrSyncCursorExpired) {
		t.Fatalf("legacy from hidden row err = %v, want expired (unchanged legacy test)", err)
	}
}

func TestSyncPageBoundedStillExpiresBehindPrunedPrefix(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	who := f.bystander
	seen := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	lost := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	live := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	pruneSyncEventsThrough(t, ctx, f.store, lost)
	if _, err := f.store.ListSyncPage(ctx, who.Account.ID, who.Device.ID, seen, 100, true); !errors.Is(err, ErrSyncCursorExpired) {
		t.Fatalf("bounded behind prune err = %v, want expired", err)
	}
	if _, err := f.store.ListSyncPage(ctx, who.Account.ID, who.Device.ID, live-1, 100, true); err != nil {
		t.Fatalf("bounded at the prune edge: %v", err)
	}
}

// VAL-308: without the opt-in the scan has no budget.
func TestSyncPageUnboundedIgnoresBudget(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	old := scopedSyncScanBudget
	scopedSyncScanBudget = 3
	t.Cleanup(func() { scopedSyncScanBudget = old })
	start := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	for i := 0; i < 8; i++ {
		f.send(t, ctx, "ub"+string(rune('a'+i)), nil)
	}
	visibleID := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	events, err := f.store.ListSyncEvents(ctx, f.blocker.Account.ID, f.blocker.Device.ID, start, 100)
	if err != nil || len(events) != 1 || events[0].ID != visibleID {
		t.Fatalf("events = %v, %v", pageEventIDs(events), err)
	}
}
