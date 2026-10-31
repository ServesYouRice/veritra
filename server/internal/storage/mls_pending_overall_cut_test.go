package storage

import (
	"context"
	"testing"
)

func (f *pendingFixture) read() ([]MLSPendingChange, bool) {
	f.t.Helper()
	changes, cut, err := f.store.ListMLSPendingChangesRead(f.ctx, f.owner.Account.ID, f.owner.Device.ID)
	if err != nil {
		f.t.Fatal(err)
	}
	return changes, cut
}

// One conversation over its own cap is flagged truncated, but the read as a
// whole was not cut: no conversation is missing, and the client must be able
// to tell (D68 hold release).
func TestPendingChangesPerConversationCapIsNotAnOverallCut(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	f.guestDevices("big", 300, -1)
	group := f.group()
	changes, cut := f.read()
	if len(changes) != 1 || changes[0].ConversationID != group.ID || !changes[0].Truncated {
		t.Fatalf("changes = %+v, want one truncated item for %s", changes, group.ID)
	}
	if cut {
		t.Fatal("a per-conversation cap reported the whole read as cut")
	}
}

// Past the overall cap the read says so, and every item stays flagged
// truncated for clients that predate the response-level flag.
func TestPendingChangesOverallCapIsReported(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	f.guestDevices("many", 260, -1)
	for i := 0; i < 9; i++ {
		f.group()
	}
	changes, cut := f.read()
	if !cut {
		t.Fatal("a read past the overall cap was not reported as cut")
	}
	for _, change := range changes {
		if !change.Truncated {
			t.Fatalf("item %s is not flagged truncated in a cut read", change.ConversationID)
		}
	}
	// A small read is not cut.
	g := newPendingFixture(t, ctx)
	g.guestDevices("few", 3, -1)
	g.group()
	if changes, cut := g.read(); cut || len(changes) != 1 || changes[0].Truncated {
		t.Fatalf("small read: cut = %v, changes = %+v", cut, changes)
	}
}
