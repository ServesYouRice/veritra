package storage

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"private-messenger/server/internal/franking"
	"private-messenger/server/migrations"
)

// A key revision alone does not name a key: it restarts at 1 when the owner
// who published the key is deleted and another owner publishes. A report
// sealed to the old key must then be refused, not stored under the new key
// where nobody can open it.
func TestReportToARepublishedKeyIsRefusedAtTheSameRevision(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	seedHistorical(t, store)
	now := "2026-01-01T00:00:00Z"
	for _, statement := range []string{
		`INSERT INTO accounts(id, username, password_hash, role, status, created_at) VALUES('acct_c', 'carol', 'h', 'owner', 'active', '` + now + `')`,
		`INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES('dev_c', 'acct_c', 'c', X'01', '` + now + `')`,
		`INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, frank_commit, attachment_refs_json, created_at)
			VALUES('msg_f', 'conv_dm', 'acct_a', 'dev_a', 'kf', X'01', 'mls10-openmls-v1', '{}', zeroblob(32), '[]', '` + now + `')`,
	} {
		if _, err := store.db.ExecContext(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	first, second := bytes.Repeat([]byte{1}, 32), bytes.Repeat([]byte{2}, 32)
	sealed := append([]byte("VRP1"), bytes.Repeat([]byte{9}, 64)...)

	inbox, err := store.SetInstanceReportKey(ctx, "acct_a", first)
	if err != nil || inbox.KeyRev != 1 {
		t.Fatalf("publish: rev=%d err=%v", inbox.KeyRev, err)
	}
	// acct_a (an owner) is deleted, which drops the key it published; the
	// other owner publishes a different key, again at revision 1.
	if _, err := store.DeleteAccountData(ctx, "acct_a"); err != nil {
		t.Fatalf("delete owner: %v", err)
	}
	inbox, err = store.SetInstanceReportKey(ctx, "acct_c", second)
	if err != nil || inbox.KeyRev != 1 {
		t.Fatalf("republish: rev=%d err=%v", inbox.KeyRev, err)
	}

	in := CreateReportInput{ReporterAccountID: "acct_b", ConversationID: "conv_dm", EnvelopeID: "msg_f", KeyRev: 1, RecipientKey: first, Sealed: sealed}
	if _, err := store.CreateReport(ctx, in); !errors.Is(err, ErrReportInboxChanged) {
		t.Fatalf("report sealed to the old key: %v, want ErrReportInboxChanged", err)
	}
	in.RecipientKey = second
	report, err := store.CreateReport(ctx, in)
	if err != nil {
		t.Fatalf("report sealed to the current key: %v", err)
	}
	if !bytes.Equal(report.RecipientPublicKey, second) || report.InboxKind != franking.InboxInstanceOwner {
		t.Fatalf("report routed to %s with key %x", report.InboxKind, report.RecipientPublicKey)
	}
}
