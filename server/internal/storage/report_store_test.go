package storage

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/franking"
	"private-messenger/server/migrations"
)

func reportStoreWithOwners(t *testing.T) *Store {
	t.Helper()
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
	} {
		if _, err := store.db.ExecContext(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	return store
}

func sealedFor(b byte) []byte { return append([]byte("VRP1"), bytes.Repeat([]byte{b}, 64)...) }

const storeReportID = "rpt-store-00000001"

// A key revision alone does not name a key: it restarts at 1 when the owner
// who published the key is deleted and another owner publishes. A report
// sealed to the old key must then be refused, not stored under the new key
// where nobody can open it. With one key per owner (D95) the deleted owner's
// copy is refused too: there is no such recipient any more.
func TestReportToARepublishedKeyIsRefusedAtTheSameRevision(t *testing.T) {
	ctx := context.Background()
	store := reportStoreWithOwners(t)
	first, second := bytes.Repeat([]byte{1}, 32), bytes.Repeat([]byte{2}, 32)

	recipient, err := store.SetInstanceReportKey(ctx, "acct_a", first)
	if err != nil || recipient.KeyRev != 1 || recipient.InboxID != "acct_a" {
		t.Fatalf("publish: %+v err=%v", recipient, err)
	}
	// acct_a (an owner) is deleted, which drops the key it published; the
	// other owner publishes a different key, again at revision 1.
	if _, err := store.DeleteAccountData(ctx, "acct_a"); err != nil {
		t.Fatalf("delete owner: %v", err)
	}
	if _, err := store.ReportInboxForConversation(ctx, "conv_dm", "acct_b"); !errors.Is(err, ErrReportInboxUnavailable) {
		t.Fatalf("inbox after the only key's owner left: %v", err)
	}
	recipient, err = store.SetInstanceReportKey(ctx, "acct_c", second)
	if err != nil || recipient.KeyRev != 1 {
		t.Fatalf("republish: %+v err=%v", recipient, err)
	}

	in := CreateReportInput{ReporterAccountID: "acct_b", ConversationID: "conv_dm", ReportID: storeReportID, Copies: []ReportCopyInput{{InboxID: "acct_a", KeyRev: 1, RecipientKey: first, Sealed: sealedFor(9)}}}
	if _, err := store.CreateReport(ctx, in); !errors.Is(err, ErrReportInboxChanged) {
		t.Fatalf("report sealed to the departed owner's key: %v, want ErrReportInboxChanged", err)
	}
	in.Copies = []ReportCopyInput{{InboxID: "acct_c", KeyRev: 1, RecipientKey: first, Sealed: sealedFor(9)}}
	if _, err := store.CreateReport(ctx, in); !errors.Is(err, ErrReportInboxChanged) {
		t.Fatalf("report sealed to the old key under the new owner: %v, want ErrReportInboxChanged", err)
	}
	in.Copies = []ReportCopyInput{{InboxID: "acct_c", KeyRev: 1, RecipientKey: second, Sealed: sealedFor(9)}}
	reports, err := store.CreateReport(ctx, in)
	if err != nil || len(reports) != 1 {
		t.Fatalf("report sealed to the current key: %v", err)
	}
	if !bytes.Equal(reports[0].RecipientPublicKey, second) || reports[0].InboxKind != franking.InboxInstanceOwner || reports[0].InboxID != "acct_c" {
		t.Fatalf("report routed to %s/%s with key %x", reports[0].InboxKind, reports[0].InboxID, reports[0].RecipientPublicKey)
	}
}

// One owner leaving takes its key and the copies sealed to it; the other
// owner's copy stays, and a demoted owner is no longer a recipient.
func TestOwnerLeavingDropsItsKeyAndCopies(t *testing.T) {
	ctx := context.Background()
	store := reportStoreWithOwners(t)
	keyA, keyC := bytes.Repeat([]byte{1}, 32), bytes.Repeat([]byte{2}, 32)
	if _, err := store.SetInstanceReportKey(ctx, "acct_a", keyA); err != nil {
		t.Fatal(err)
	}
	if _, err := store.SetInstanceReportKey(ctx, "acct_c", keyC); err != nil {
		t.Fatal(err)
	}
	inbox, err := store.ReportInboxForConversation(ctx, "conv_dm", "acct_b")
	if err != nil || len(inbox.Recipients) != 2 || inbox.Recipients[0].InboxID != "acct_a" || inbox.Recipients[1].InboxID != "acct_c" {
		t.Fatalf("inbox: %+v err=%v", inbox, err)
	}
	in := CreateReportInput{ReporterAccountID: "acct_b", ConversationID: "conv_dm", ReportID: storeReportID, Copies: []ReportCopyInput{
		{InboxID: "acct_a", KeyRev: 1, RecipientKey: keyA, Sealed: sealedFor(1)},
		{InboxID: "acct_c", KeyRev: 1, RecipientKey: keyC, Sealed: sealedFor(2)},
	}}
	if _, err := store.CreateReport(ctx, in); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DeleteAccountData(ctx, "acct_a"); err != nil {
		t.Fatal(err)
	}
	var left int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM reports WHERE inbox_id = 'acct_a'`).Scan(&left); err != nil || left != 0 {
		t.Fatalf("copies for the deleted owner: %d err=%v", left, err)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM reports WHERE inbox_id = 'acct_c'`).Scan(&left); err != nil || left != 1 {
		t.Fatalf("copies for the other owner: %d err=%v", left, err)
	}
	// A demoted owner stops being a recipient and cannot read the inbox.
	if _, err := store.db.ExecContext(ctx, `UPDATE accounts SET role = 'member' WHERE id = 'acct_c'`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReportInboxForConversation(ctx, "conv_dm", "acct_b"); !errors.Is(err, ErrReportInboxUnavailable) {
		t.Fatalf("inbox with no owner key: %v", err)
	}
	if _, err := store.ListReports(ctx, "acct_c", franking.InboxInstanceOwner, "acct_c", "", 0); !errors.Is(err, ErrForbidden) {
		t.Fatalf("demoted owner listed its inbox: %v", err)
	}
}

// D95: a report goes after 90 days if nobody dismissed it first.
func TestReportsArePrunedAfterNinetyDays(t *testing.T) {
	ctx := context.Background()
	store := reportStoreWithOwners(t)
	key := bytes.Repeat([]byte{1}, 32)
	if _, err := store.SetInstanceReportKey(ctx, "acct_a", key); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"rpt-store-00000001", "rpt-store-00000002"} {
		in := CreateReportInput{ReporterAccountID: "acct_b", ConversationID: "conv_dm", ReportID: id, Copies: []ReportCopyInput{{InboxID: "acct_a", KeyRev: 1, RecipientKey: key, Sealed: sealedFor(1)}}}
		if _, err := store.CreateReport(ctx, in); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().UTC()
	old := formatTime(now.Add(-ReportRetention - time.Hour))
	if _, err := store.db.ExecContext(ctx, `UPDATE reports SET created_at = ? WHERE report_id = 'rpt-store-00000001'`, old); err != nil {
		t.Fatal(err)
	}
	removed, err := store.PruneReports(ctx, now)
	if err != nil || removed != 1 {
		t.Fatalf("pruned %d, err=%v", removed, err)
	}
	var left int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM reports`).Scan(&left); err != nil || left != 1 {
		t.Fatalf("reports left: %d err=%v", left, err)
	}
	// Just inside the window stays.
	inside := formatTime(now.Add(-ReportRetention + time.Hour))
	if _, err := store.db.ExecContext(ctx, `UPDATE reports SET created_at = ?`, inside); err != nil {
		t.Fatal(err)
	}
	if removed, err := store.PruneReports(ctx, now); err != nil || removed != 0 {
		t.Fatalf("pruned %d inside the window, err=%v", removed, err)
	}
}
