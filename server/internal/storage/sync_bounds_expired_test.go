package storage

import (
	"context"
	"testing"
	"time"
)

// SyncBounds must not report an event sync never serves: a message whose
// envelope expired but is not pruned yet is hidden from every device, so it
// is neither the oldest nor the latest bound.
func TestSyncBoundsSkipExpiredHiddenEvents(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	reader := f.bystander // blocked nobody, so only expiry hides events
	soon := time.Now().UTC().Add(time.Hour)

	_, oldestBefore, _, err := f.store.SyncBounds(ctx, reader.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	first, firstEvent := f.send(t, ctx, "first-expiring", &soon)
	_, keptEvent := f.send(t, ctx, "kept", nil)
	last, lastEvent := f.send(t, ctx, "last-expiring", &soon)
	f.expire(t, ctx, first.ID)
	f.expire(t, ctx, last.ID)

	seen := f.eventIDs(t, ctx, reader)
	if seen[firstEvent] || seen[lastEvent] || !seen[keptEvent] {
		t.Fatalf("sync serves %v; want the kept event only", seen)
	}
	_, oldest, latest, err := f.store.SyncBounds(ctx, reader.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if latest == lastEvent || latest != keptEvent {
		t.Fatalf("latest bound = %d, want the kept event %d (expired %d is hidden)", latest, keptEvent, lastEvent)
	}
	if oldest == firstEvent || (oldestBefore != 0 && oldest != oldestBefore) {
		t.Fatalf("oldest bound = %d, want %d (expired %d is hidden)", oldest, oldestBefore, firstEvent)
	}
}
