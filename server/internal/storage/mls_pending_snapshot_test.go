package storage

import (
	"context"
	"testing"
)

// A commit that lands while the pending changes are being read must not leave
// one item with the epoch of the old group and the coordinator of the new one.
func TestPendingChangesComeFromOneSnapshot(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	f.guestDevices("snap", 1, 0)
	group := f.group()
	committed := false
	f.store.afterPendingChangesRead = func() {
		if committed {
			return
		}
		committed = true
		// A commit by another device: the epoch moves on, and a device with a
		// lower id joins the roster, so it becomes the coordinator.
		f.exec(`UPDATE conversation_mls_groups SET epoch = epoch + 1 WHERE conversation_id = ?`, group.ID)
		f.exec(`INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES('dev_0', ?, 'new', X'01', NULL, 'hash', ?)`, f.owner.Account.ID, nowString())
		f.exec(`INSERT INTO conversation_mls_devices(conversation_id, device_id, account_id, joined_after_event_id, joined_epoch) VALUES(?, 'dev_0', ?, 0, 1)`, group.ID, f.owner.Account.ID)
	}
	changes := f.list()
	if len(changes) != 1 || changes[0].ConversationID != group.ID {
		t.Fatalf("changes = %#v", changes)
	}
	if changes[0].Epoch != 1 || changes[0].CoordinatorDeviceID != f.owner.Device.ID {
		t.Fatalf("epoch %d with coordinator %s: want the group as it was when the read began (epoch 1, coordinator %s)",
			changes[0].Epoch, changes[0].CoordinatorDeviceID, f.owner.Device.ID)
	}
	if !committed {
		t.Fatal("the test hook never ran")
	}
	// The next read sees the commit, whole.
	after := f.list()
	if len(after) != 1 || after[0].Epoch != 2 || after[0].CoordinatorDeviceID != "dev_0" {
		t.Fatalf("after the commit: %#v, want epoch 2 and coordinator dev_0", after)
	}
}
