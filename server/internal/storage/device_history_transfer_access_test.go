package storage

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// Only the link's recipient (its session or its claim token) reads, downloads,
// acknowledges or cancels a history copy; another device of the same account,
// another account's device and a wrong claim token are all refused, and none
// of them can consume the copy (K2: wrong device).
func TestHistoryTransferOtherDevicesCannotReadAckOrCancel(t *testing.T) {
	f := newHistoryFixture(t)
	ctx := context.Background()
	tfr := f.upload(t)
	others := map[string]HistoryAccess{
		"another device of the account":     {AccountID: f.source.AccountID, DeviceID: "dev_third_device"},
		"the recipient id, other account":   {AccountID: "acct_someone_else", DeviceID: f.recipient.DeviceID},
		"a wrong claim token":               {ClaimTokenHash: strings.Repeat("c", 64)},
		"a session that also names a claim": {AccountID: f.recipient.AccountID, DeviceID: f.recipient.DeviceID, ClaimTokenHash: f.claim.ClaimTokenHash},
	}
	for name, access := range others {
		t.Run(name, func(t *testing.T) {
			for _, content := range []bool{false, true} {
				if _, err := f.store.HistoryTransferForAccess(ctx, f.link.ID, access, content); !errors.Is(err, ErrForbidden) {
					t.Fatalf("read (content %v): %v", content, err)
				}
			}
			if _, err := f.store.AcknowledgeHistoryTransfer(ctx, f.link.ID, access, tfr.TransferID, tfr.CiphertextSHA256); !errors.Is(err, ErrForbidden) {
				t.Fatalf("ack: %v", err)
			}
			if err := f.store.CancelHistoryTransfer(ctx, f.link.ID, access); !errors.Is(err, ErrForbidden) {
				t.Fatalf("cancel: %v", err)
			}
		})
	}
	got, err := f.store.HistoryTransferForAccess(ctx, f.link.ID, f.recipient, true)
	if err != nil || got.State != "active" || len(got.Handoff) == 0 {
		t.Fatalf("the recipient lost its copy: %+v %v", got, err)
	}
}
