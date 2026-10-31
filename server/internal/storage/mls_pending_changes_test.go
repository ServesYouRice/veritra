package storage

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"private-messenger/server/internal/domain"
)

// pendingFixture seeds groups the requester's device belongs to, directly in
// the tables, so a test can build far more pending work than the API makes.
type pendingFixture struct {
	t     *testing.T
	ctx   context.Context
	store *Store
	owner AccountDevice
	guest string // account whose devices are the pending adds
}

func newPendingFixture(t *testing.T, ctx context.Context) *pendingFixture {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	guest := registerTestMember(t, ctx, store, invite.Code, "guest")
	return &pendingFixture{t: t, ctx: ctx, store: store, owner: owner, guest: guest.Account.ID}
}

func (f *pendingFixture) exec(query string, args ...any) {
	f.t.Helper()
	if _, err := f.store.db.ExecContext(f.ctx, query, args...); err != nil {
		f.t.Fatalf("%s: %v", query, err)
	}
}

// group creates a conversation of the owner and the guest whose MLS roster
// holds only the owner's device.
func (f *pendingFixture) group() domain.Conversation {
	f.t.Helper()
	conversation, err := f.store.CreateConversation(f.ctx, CreateConversationInput{Kind: "group", CreatedBy: f.owner.Account.ID, MemberAccountIDs: []string{f.guest}})
	if err != nil {
		f.t.Fatal(err)
	}
	f.exec(`INSERT INTO conversation_mls_groups(conversation_id, epoch, updated_at) VALUES(?, 1, ?)`, conversation.ID, nowString())
	f.exec(`INSERT INTO conversation_mls_devices(conversation_id, device_id, account_id, joined_after_event_id, joined_epoch) VALUES(?, ?, ?, 0, 0)`,
		conversation.ID, f.owner.Device.ID, f.owner.Account.ID)
	return conversation
}

// guestDevices gives the guest count more devices. The ones from claimable on
// have a usable key package; the rest cannot be claimed.
func (f *pendingFixture) guestDevices(prefix string, count, claimableFrom int) {
	f.t.Helper()
	for i := 0; i < count; i++ {
		id := fmt.Sprintf("%s_%04d", prefix, i)
		f.exec(`INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES(?, ?, 'guest device', X'01', NULL, 'hash', ?)`, id, f.guest, nowString())
		if claimableFrom >= 0 && i >= claimableFrom {
			f.exec(`INSERT INTO device_key_packages(id, device_id, key_package, ciphersuite, created_at, expires_at) VALUES(?, ?, X'02', ?, ?, '2999-01-01T00:00:00Z')`,
				"kp_"+id, id, openMLSCiphersuite, nowString())
		}
	}
}

func (f *pendingFixture) list() []MLSPendingChange {
	f.t.Helper()
	changes, err := f.store.ListMLSPendingChanges(f.ctx, f.owner.Account.ID, f.owner.Device.ID)
	if err != nil {
		f.t.Fatal(err)
	}
	return changes
}

func TestPendingChangesAddBacklogDoesNotHideRemovals(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	// Many groups, each with more package-less devices to add than the old
	// global cap allowed across all of them.
	f.guestDevices("pending_add", 260, -1)
	var groups []domain.Conversation
	for i := 0; i < 9; i++ {
		groups = append(groups, f.group())
	}
	// Each group has the guest's 261 devices (one registered, 260 added) to
	// add: 2349 rows, past 2000. The last group by id also has a device of a
	// departed account in its roster, which a removal must drop.
	last := groups[0]
	for _, g := range groups {
		if g.ID > last.ID {
			last = g
		}
	}
	f.exec(`INSERT INTO accounts(id, username, role, status, password_hash, created_at) VALUES('acct_departed', 'departed', 'member', 'active', '!', ?)`, nowString())
	f.exec(`INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES('dev_departed', 'acct_departed', 'old', X'01', NULL, 'hash', ?)`, nowString())
	f.exec(`INSERT INTO conversation_mls_devices(conversation_id, device_id, account_id, joined_after_event_id, joined_epoch) VALUES(?, 'dev_departed', 'acct_departed', 0, 0)`, last.ID)

	changes := f.list()
	var found bool
	for _, change := range changes {
		if change.ConversationID == last.ID {
			found = len(change.Remove) == 1 && change.Remove[0].DeviceID == "dev_departed"
		}
	}
	if !found {
		t.Fatalf("the removal in %s is missing from %d listed groups", last.ID, len(changes))
	}
	if len(changes) != len(groups) {
		t.Fatalf("listed %d groups, want all %d", len(changes), len(groups))
	}
	for _, change := range changes {
		if len(change.Add) > maxMLSBundleChanges || len(change.Remove) > maxMLSBundleChanges {
			t.Fatalf("group %s lists %d adds and %d removes, over the %d cap", change.ConversationID, len(change.Add), len(change.Remove), maxMLSBundleChanges)
		}
		if len(change.Add) == maxMLSBundleChanges && !change.Truncated {
			t.Fatalf("group %s was cut to %d adds without a truncation flag", change.ConversationID, maxMLSBundleChanges)
		}
	}
}

func TestPendingChangesListClaimableDevicesBeforeUnclaimableOnes(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	// 300 devices without a package sort before the one that has one.
	f.guestDevices("a_unclaimable", 300, -1)
	f.guestDevices("z_claimable", 1, 0)
	group := f.group()

	changes := f.list()
	if len(changes) != 1 || changes[0].ConversationID != group.ID {
		t.Fatalf("changes = %#v", changes)
	}
	change := changes[0]
	if len(change.Add) != maxMLSBundleChanges || !change.Truncated {
		t.Fatalf("add list has %d entries, truncated = %v, want %d and true", len(change.Add), change.Truncated, maxMLSBundleChanges)
	}
	// Two devices can be claimed: the guest's registered device and the one
	// seeded above. Both come before every device without a package.
	claimable := 0
	for i, add := range change.Add {
		isClaimable := add.DeviceID == "z_claimable_0000" || !strings.HasPrefix(add.DeviceID, "a_unclaimable_")
		if isClaimable && i != claimable {
			t.Fatalf("claimable device %s at position %d, behind %d unclaimable ones", add.DeviceID, i, i-claimable)
		}
		if isClaimable {
			claimable++
		}
	}
	if claimable != 2 {
		t.Fatalf("%d claimable devices listed, want 2", claimable)
	}
	// Repeated calls return the same list in the same order.
	again := f.list()
	if !reflect.DeepEqual(changes, again) {
		t.Fatal("two calls returned different pending changes")
	}
	// A short list is not flagged.
	f.exec(`DELETE FROM devices WHERE id LIKE 'a_unclaimable_%' AND id >= 'a_unclaimable_0010'`)
	if short := f.list(); len(short) != 1 || short[0].Truncated || len(short[0].Add) != 12 {
		t.Fatalf("short list = %#v, want 12 adds and no truncation flag", short)
	}
}
