package storage

import (
	"context"
	"errors"
	"sort"
	"testing"
)

// The scoped streams together must show exactly what the legacy global
// stream shows: same visibility, nothing added, nothing lost.
func TestScopedSyncStreamsEqualLegacyStream(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	f.send(t, ctx, "a", nil)
	accountSyncEvent(t, ctx, f.store, f.blocker.Account.ID, "")
	accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "other-device")
	conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	f.send(t, ctx, "b", nil)
	// A welcome-like event: the account's own, naming the conversation.
	bystander := f.bystander.Account.ID
	if _, err := f.store.SaveSyncEvent(ctx, "test.welcome", &bystander, f.conversation.ID, map[string]string{"k": "v"}); err != nil {
		t.Fatal(err)
	}

	for _, who := range []AccountDevice{f.blocker, f.sender, f.bystander} {
		legacy, err := f.store.ListSyncEvents(ctx, who.Account.ID, who.Device.ID, 0, 200)
		if err != nil {
			t.Fatal(err)
		}
		acct, err := f.store.ListAccountSyncEvents(ctx, who.Account.ID, who.Device.ID, 0, 200)
		if err != nil {
			t.Fatal(err)
		}
		conv, err := f.store.ListConversationSyncEvents(ctx, who.Account.ID, who.Device.ID, f.conversation.ID, 0, 200)
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range acct {
			if e.ConversationID != "" {
				t.Fatalf("account stream carried conversation event %d", e.ID)
			}
		}
		got := pageEventIDs(append(append(acct[:0:0], acct...), conv...))
		sort.Slice(got, func(i, j int) bool { return got[i] < got[j] })
		want := pageEventIDs(legacy)
		sort.Slice(want, func(i, j int) bool { return want[i] < want[j] })
		if len(got) != len(want) {
			t.Fatalf("%s: scoped %v, legacy %v", who.Account.ID, got, want)
		}
		for i := range got {
			if got[i] != want[i] {
				t.Fatalf("%s: scoped %v, legacy %v", who.Account.ID, got, want)
			}
		}
	}
}

func TestScopedConversationSyncRejectsOutsiderAndPaginates(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	invite, err := f.store.CreateInvite(ctx, f.blocker.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	outsider := registerTestMember(t, ctx, f.store, invite.Code, "outsider")
	if _, err := f.store.ListConversationSyncEvents(ctx, outsider.Account.ID, outsider.Device.ID, f.conversation.ID, 0, 10); !errors.Is(err, ErrForbidden) {
		t.Fatalf("outsider err = %v, want ErrForbidden", err)
	}
	for i := 0; i < 3; i++ {
		conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	}
	page, err := f.store.ListConversationSyncEvents(ctx, f.bystander.Account.ID, f.bystander.Device.ID, f.conversation.ID, 0, 2)
	if err != nil || len(page) != 2 {
		t.Fatalf("page = %v, %v", pageEventIDs(page), err)
	}
	next, err := f.store.ListConversationSyncEvents(ctx, f.bystander.Account.ID, f.bystander.Device.ID, f.conversation.ID, page[1].ID, 2)
	if err != nil || len(next) == 0 || next[0].ID <= page[1].ID {
		t.Fatalf("next = %v, %v", pageEventIDs(next), err)
	}
}

// Pruning events of one conversation expires only that conversation's
// cursor, not another conversation's nor the account stream's.
func TestScopedSyncExpiryIsPerScope(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	other, err := f.store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: f.sender.Account.ID, MemberAccountIDs: []string{f.bystander.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	b := f.bystander
	seenA := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	seenB := conversationSyncEvent(t, ctx, f.store, "conversation.updated", other.ID)
	conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	liveB := conversationSyncEvent(t, ctx, f.store, "conversation.updated", other.ID)
	pruneSyncEventsThrough(t, ctx, f.store, liveB-1)
	conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)

	if _, err := f.store.ListConversationSyncEvents(ctx, b.Account.ID, b.Device.ID, f.conversation.ID, seenA, 10); !errors.Is(err, ErrSyncCursorExpired) {
		t.Fatalf("pruned conversation err = %v, want expired", err)
	}
	if _, err := f.store.ListConversationSyncEvents(ctx, b.Account.ID, b.Device.ID, other.ID, liveB-1, 10); err != nil {
		t.Fatalf("cursor at the last pruned event of B: %v", err)
	}
	_ = seenB
	if _, err := f.store.ListAccountSyncEvents(ctx, b.Account.ID, b.Device.ID, seenA, 10); err != nil {
		t.Fatalf("account stream expired by conversation prune: %v", err)
	}
}

// A run of hidden events (here: a blocked sender's) is crossed once. Each
// request examines at most the scan budget, reports where it stopped, and a
// cursor at that position (a hidden row) is accepted, not called expired.
func TestScopedConversationSyncCrossesHiddenRunWithBudget(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	old := scopedSyncScanBudget
	scopedSyncScanBudget = 3
	t.Cleanup(func() { scopedSyncScanBudget = old })
	var hidden []int64
	for i := 0; i < 8; i++ {
		_, id := f.send(t, ctx, "h"+string(rune('a'+i)), nil)
		hidden = append(hidden, id)
	}
	visibleID := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	who := f.blocker

	cursor := int64(0)
	var got []int64
	pages := 0
	for {
		page, err := f.store.ListConversationSyncPage(ctx, who.Account.ID, who.Device.ID, f.conversation.ID, cursor, 100, true)
		if err != nil {
			t.Fatalf("page from %d: %v", cursor, err)
		}
		pages++
		got = append(got, pageEventIDs(page.Events)...)
		if page.ScannedThrough < cursor || (page.Truncated && page.ScannedThrough <= cursor) {
			t.Fatalf("cursor %d did not advance: through %d", cursor, page.ScannedThrough)
		}
		cursor = page.ScannedThrough
		if !page.Truncated {
			break
		}
		if pages > 10 {
			t.Fatal("did not terminate")
		}
	}
	if len(got) != 1 || got[0] != visibleID {
		t.Fatalf("events = %v, want only %d", got, visibleID)
	}
	if cursor != visibleID {
		t.Fatalf("scanned through %d, want %d", cursor, visibleID)
	}
	if pages != 3 {
		t.Fatalf("pages = %d, want 3 (3+3+3 candidates)", pages)
	}
	// A cursor on a hidden row is not expired, though no visible row
	// precedes it. A cursor from before the prune marks existed takes the
	// legacy row test, which would call it expired.
	if _, err := f.store.db.ExecContext(ctx, `DELETE FROM sync_prune_state`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ListConversationSyncPage(ctx, who.Account.ID, who.Device.ID, f.conversation.ID, hidden[2], 100, true); err != nil {
		t.Fatalf("hidden-row cursor: %v", err)
	}
}

// Without the opt-in the scan has no budget: a client that does not know
// scan_truncated still gets the later visible event.
func TestScopedConversationSyncUnboundedIgnoresBudget(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	old := scopedSyncScanBudget
	scopedSyncScanBudget = 3
	t.Cleanup(func() { scopedSyncScanBudget = old })
	for i := 0; i < 8; i++ {
		f.send(t, ctx, "u"+string(rune('a'+i)), nil)
	}
	conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	events, err := f.store.ListConversationSyncEvents(ctx, f.blocker.Account.ID, f.blocker.Device.ID, f.conversation.ID, 0, 100)
	if err != nil || len(events) != 1 {
		t.Fatalf("events = %v, %v", pageEventIDs(events), err)
	}
}

// The account scope has no hidden rows: it scans through its last event.
func TestScopedAccountSyncPageReportsScanPosition(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	id := accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	who := f.bystander
	page, err := f.store.ListAccountSyncPage(ctx, who.Account.ID, who.Device.ID, 0, 10)
	if err != nil || page.Truncated || page.ScannedThrough != id {
		t.Fatalf("page = %+v, %v; want through %d", page, err, id)
	}
	empty, err := f.store.ListAccountSyncPage(ctx, who.Account.ID, who.Device.ID, id, 10)
	if err != nil || len(empty.Events) != 0 || empty.ScannedThrough != id {
		t.Fatalf("empty = %+v, %v", empty, err)
	}
}
