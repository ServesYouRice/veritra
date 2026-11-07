package storage

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// W11: ex-members lose the group record, a deleted account loses its record,
// and the account export carries the encrypted record.
func TestProfileExMemberAccountDeleteAndExport(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 4, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	group, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	key := strings.Repeat("a", 32)
	blob := append([]byte("VPE1"), make([]byte, 4096+24)...)
	if _, _, err := store.PutProfile(ctx, ProfileWrite{Kind: ProfileKindConversation, SubjectID: group.ID, WriterAccountID: owner.Account.ID, KeyID: key, Ciphertext: blob}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.PutProfile(ctx, ProfileWrite{Kind: ProfileKindAccount, SubjectID: bob.Account.ID, WriterAccountID: bob.Account.ID, KeyID: key, Ciphertext: blob}); err != nil {
		t.Fatal(err)
	}
	// An account cannot be written by anyone else.
	if _, _, err := store.PutProfile(ctx, ProfileWrite{Kind: ProfileKindAccount, SubjectID: bob.Account.ID, WriterAccountID: owner.Account.ID, KeyID: key, Ciphertext: blob, ExpectedVersion: 1}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("foreign account write err = %v", err)
	}
	// Ex-member: dropping the membership makes the group record unreadable and
	// the account record unreadable (no shared conversation left).
	if _, err := store.db.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, group.ID, bob.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetProfile(ctx, bob.Account.ID, ProfileKindConversation, group.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("ex-member group read err = %v", err)
	}
	if _, err := store.GetProfile(ctx, owner.Account.ID, ProfileKindAccount, bob.Account.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("no-shared-conversation account read err = %v", err)
	}
	if _, err := store.GetProfile(ctx, bob.Account.ID, ProfileKindAccount, bob.Account.ID); err != nil {
		t.Fatalf("own read err = %v", err)
	}
	// Export holds the owner's own record only, as hex ciphertext.
	export, err := store.ExportAccount(ctx, bob.Account.ID, ExportAccountOptions{})
	if err != nil {
		t.Fatal(err)
	}
	items := export.Categories["encrypted_profile"]
	if len(items) != 1 {
		t.Fatalf("export items = %d", len(items))
	}
	var item map[string]interface{}
	if err := json.Unmarshal(items[0], &item); err != nil || item["id"] != bob.Account.ID || item["key_id"] != key {
		t.Fatalf("export item = %v err=%v", item, err)
	}
	// Account deletion removes the record.
	if _, err := store.DeleteAccountData(ctx, bob.Account.ID); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM encrypted_profiles WHERE subject_kind = 'account' AND subject_id = ?`, bob.Account.ID).Scan(&n); err != nil || n != 0 {
		t.Fatalf("rows after delete = %d err=%v", n, err)
	}
}

// W11: records count toward the writer's storage limit.
func TestProfileWritesCountTowardStorageLimit(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	store.limits.AccountStorageBytes = 5000
	blob := append([]byte("VPE1"), make([]byte, 4096+24)...)
	write := func(id string) error {
		g, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
		if err != nil {
			t.Fatal(err)
		}
		_, _, err = store.PutProfile(ctx, ProfileWrite{Kind: ProfileKindConversation, SubjectID: g.ID, WriterAccountID: owner.Account.ID, KeyID: strings.Repeat("b", 32), Ciphertext: blob})
		return err
	}
	if err := write("a"); err != nil {
		t.Fatalf("first write: %v", err)
	}
	if err := write("b"); !errors.Is(err, ErrStorageQuota) {
		t.Fatalf("second write err = %v, want quota", err)
	}
}
