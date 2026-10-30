package storage

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/domain"
)

type v3Fixture struct {
	store        *Store
	owner        AccountDevice
	link         DeviceLinkV3
	reservation  EnrollmentReservation
	input        DeviceLinkV3ClaimInput
	privateKey   ed25519.PrivateKey
	claimToken   string
	deviceSecret string
	sessionToken string
	approvalTag  []byte
}

func newV3Fixture(t *testing.T) *v3Fixture {
	t.Helper()
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { _ = store.Close() })
	f := &v3Fixture{store: store, owner: createTestOwner(t, ctx, store), approvalTag: bytes.Repeat([]byte{9}, 32)}
	var err error
	f.link, err = store.CreateDeviceLinkV3(ctx, f.owner.Account.ID, f.owner.Device.ID, testLinkLocator(t), "https://example.test", 0)
	if err != nil {
		t.Fatal(err)
	}
	requestID := strings.Repeat("1", 64)
	f.reservation, err = store.ReserveDeviceLinkV3(ctx, f.link.Code, requestID)
	if err != nil {
		t.Fatal(err)
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	f.privateKey = private
	f.claimToken, _, err = auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	f.deviceSecret, _, err = auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	f.sessionToken, _, err = auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	f.input = DeviceLinkV3ClaimInput{Code: f.link.Code, ProtocolVersion: DeviceLinkV3Protocol, ServerOrigin: f.link.ServerOrigin, ReservationRequestID: requestID, EnrollmentReservationID: f.link.ID, DeviceName: "Linked phone", DeviceKeyPackage: bytes.Repeat([]byte{3}, 64), SigningKey: public, TransferPublicKey: bytes.Repeat([]byte{4}, 32), TranscriptHash: bytes.Repeat([]byte{5}, 32), ClaimTag: bytes.Repeat([]byte{6}, 32), ClaimTokenHash: auth.HashToken(f.claimToken), DeviceSecretHash: auth.HashToken(f.deviceSecret), InitialSessionTokenHash: auth.HashToken(f.sessionToken)}
	f.sign(t)
	return f
}

func (f *v3Fixture) sign(t *testing.T) {
	t.Helper()
	proof, err := DeviceLinkV3ProofMessage(f.input, f.reservation)
	if err != nil {
		t.Fatal(err)
	}
	f.input.ChallengeSignature = ed25519.Sign(f.privateKey, proof)
}

func (f *v3Fixture) claim(t *testing.T) DeviceLinkV3 {
	t.Helper()
	link, err := f.store.ClaimDeviceLinkV3(context.Background(), f.input)
	if err != nil {
		t.Fatal(err)
	}
	return link
}

func (f *v3Fixture) approve(t *testing.T) DeviceLinkV3 {
	t.Helper()
	claimed := f.claim(t)
	link, _, _, err := f.store.ApproveDeviceLinkV3(context.Background(), f.link.ID, f.owner.Account.ID, f.owner.Device.ID, claimed.ClaimRequestHash, f.input.TranscriptHash, f.approvalTag)
	if err != nil {
		t.Fatal(err)
	}
	return link
}

func (f *v3Fixture) complete(t *testing.T) DeviceLinkV3Completion {
	t.Helper()
	approved := f.approve(t)
	receipt, tag, err := f.store.CompleteDeviceLinkV3(context.Background(), f.link.ID, f.input.ClaimTokenHash, approved.ClaimRequestHash, f.input.InitialSessionTokenHash, f.input.TranscriptHash)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(tag, f.approvalTag) {
		t.Fatal("approval tag changed")
	}
	return receipt
}

func TestDeviceLinkV3ProofIndependentVector(t *testing.T) {
	input := DeviceLinkV3ClaimInput{ProtocolVersion: DeviceLinkV3Protocol, ServerOrigin: "https://example.test", Code: strings.Repeat("a", 64), ReservationRequestID: strings.Repeat("11", 32), DeviceName: "Vector phone", DeviceKeyPackage: bytes.Repeat([]byte{0x33}, 64), SigningKey: bytes.Repeat([]byte{0x22}, 32), TransferPublicKey: bytes.Repeat([]byte{0x44}, 32), TranscriptHash: bytes.Repeat([]byte{0x55}, 32), ClaimTag: bytes.Repeat([]byte{0x66}, 32), ClaimTokenHash: strings.Repeat("77", 32), DeviceSecretHash: strings.Repeat("88", 32), InitialSessionTokenHash: strings.Repeat("99", 32)}
	message, err := DeviceLinkV3ProofMessage(input, EnrollmentReservation{ID: "link_vector", AccountID: "acct_vector", DeviceID: "dev_vector", Challenge: []byte("vector-challenge")})
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(message)
	if len(message) != 481 || hex.EncodeToString(digest[:]) != "70e1a994b2e4e2878cdab80c38c26012177780bd93b2cacaf73c1699389d6f78" {
		t.Fatal("proof differs from independent native/Python vector")
	}
}

func TestDeviceLinkV3OriginsAreExactAndLoopbackHTTPOnly(t *testing.T) {
	for _, origin := range []string{"https://example.test", "https://example.test:8443", "http://localhost:8080", "http://127.0.0.1:8080", "http://127.2.3.4", "http://[::1]:8080", "https://[2001:db8::1]"} {
		if !ValidDeviceLinkV3Origin(origin) {
			t.Errorf("valid origin rejected: %s", origin)
		}
	}
	for _, origin := range []string{"https://EXAMPLE.test", "HTTPS://example.test", "https://example.test/", "https://example.test:443", "http://localhost:80", "https://example.test:08443", "https://user@example.test", "https://example.test?", "https://example.test#", "https://example.test/path", "http://localhost.example.test", "http://192.168.1.2", "http://[2001:db8::1]", " https://example.test"} {
		if ValidDeviceLinkV3Origin(origin) {
			t.Errorf("invalid origin accepted: %s", origin)
		}
	}
}

func TestDeviceLinkV3CreateReserveAndClaimRetryAreImmutable(t *testing.T) {
	f := newV3Fixture(t)
	ctx := context.Background()
	repeated, err := f.store.CreateDeviceLinkV3(ctx, f.owner.Account.ID, f.owner.Device.ID, f.link.Code, f.link.ServerOrigin, 0)
	if err != nil || repeated.ID != f.link.ID || repeated.Code != f.link.Code || !repeated.CreatedAt.Equal(f.link.CreatedAt) || !repeated.ExpiresAt.Equal(f.link.ExpiresAt) || !bytes.Equal(repeated.LinkNonce, f.link.LinkNonce) || repeated.ServerOrigin != f.link.ServerOrigin {
		t.Fatalf("create retry changed context: %v", err)
	}
	reservation, err := f.store.ReserveDeviceLinkV3(ctx, f.link.Code, f.input.ReservationRequestID)
	if err != nil || !reflect.DeepEqual(reservation, f.reservation) {
		t.Fatalf("reserve retry changed context: %v", err)
	}
	if _, err := f.store.ReserveDeviceLinkV3(ctx, f.link.Code, strings.Repeat("2", 64)); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("reservation takeover: %v", err)
	}
	if _, err := f.store.CreateDeviceLinkV3(ctx, f.owner.Account.ID, f.owner.Device.ID, f.link.Code, "https://other.test", 0); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("origin substitution: %v", err)
	}
	first := f.claim(t)
	second := f.claim(t)
	if !reflect.DeepEqual(first, second) {
		t.Fatal("lost claim response replay changed acknowledgement")
	}
	reservation, err = f.store.ReserveDeviceLinkV3(ctx, f.link.Code, f.input.ReservationRequestID)
	if err != nil || !reflect.DeepEqual(reservation, f.reservation) {
		t.Fatalf("claimed preflight replay changed context: %v", err)
	}
	f.input.DeviceName = "Relabelled phone"
	f.sign(t)
	if _, err := f.store.ClaimDeviceLinkV3(ctx, f.input); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("signed name replacement: %v", err)
	}
	f.input.DeviceName = "Linked phone"
	f.input.InitialSessionTokenHash = strings.Repeat("c", 64)
	f.sign(t)
	if _, err := f.store.ClaimDeviceLinkV3(ctx, f.input); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("credential replacement: %v", err)
	}
}

func TestDeviceLinkV3ProofAndNameValidationFailBeforeMutation(t *testing.T) {
	f := newV3Fixture(t)
	ctx := context.Background()
	original := f.input
	for _, change := range []func(*DeviceLinkV3ClaimInput){
		func(i *DeviceLinkV3ClaimInput) { i.ProtocolVersion = "veritra-device-link-v2" },
		func(i *DeviceLinkV3ClaimInput) { i.ClaimTokenHash = strings.Repeat("e", 64) },
		func(i *DeviceLinkV3ClaimInput) { i.TransferPublicKey = bytes.Repeat([]byte{8}, 32) },
		func(i *DeviceLinkV3ClaimInput) { i.DeviceName = " Linked phone" },
		func(i *DeviceLinkV3ClaimInput) { i.DeviceName = strings.Repeat("x", 65) },
		func(i *DeviceLinkV3ClaimInput) { i.ServerOrigin = "https://other.test" },
	} {
		input := original
		change(&input)
		if _, err := f.store.ClaimDeviceLinkV3(ctx, input); !errors.Is(err, ErrEnrollmentInvalid) {
			t.Fatalf("mutated proof accepted: %v", err)
		}
	}
	state, err := f.store.DeviceLinkV3ForSource(ctx, f.link.ID, f.owner.Account.ID, f.owner.Device.ID)
	if err != nil || state.State != domain.DeviceLinkPending {
		t.Fatalf("invalid proof changed state: %v", err)
	}
	f.claim(t)
}

func TestDeviceLinkV3ApprovalIsSourceDeviceBoundAndIdempotent(t *testing.T) {
	f := newV3Fixture(t)
	ctx := context.Background()
	claimed := f.claim(t)
	if _, _, _, err := f.store.ApproveDeviceLinkV3(ctx, f.link.ID, f.owner.Account.ID, "different-device", claimed.ClaimRequestHash, f.input.TranscriptHash, f.approvalTag); !errors.Is(err, ErrDeviceLinkInvalid) {
		t.Fatalf("sibling approved: %v", err)
	}
	first, device, event, err := f.store.ApproveDeviceLinkV3(ctx, f.link.ID, f.owner.Account.ID, f.owner.Device.ID, claimed.ClaimRequestHash, f.input.TranscriptHash, f.approvalTag)
	if err != nil || event == 0 {
		t.Fatalf("approval: %v", err)
	}
	second, sameDevice, repeatedEvent, err := f.store.ApproveDeviceLinkV3(ctx, f.link.ID, f.owner.Account.ID, f.owner.Device.ID, claimed.ClaimRequestHash, f.input.TranscriptHash, f.approvalTag)
	if err != nil || repeatedEvent != 0 || !reflect.DeepEqual(first, second) || !reflect.DeepEqual(device, sameDevice) {
		t.Fatalf("approval retry mutated state: %v", err)
	}
	if first.TransferExpiresAt == nil || first.ApprovedAt == nil || first.TransferExpiresAt.Sub(*first.ApprovedAt) != 7*24*time.Hour {
		t.Fatal("transfer deadline is not fixed from approval")
	}
	for query, want := range map[string]int{"SELECT COUNT(*) FROM devices": 2, "SELECT COUNT(*) FROM sync_events WHERE event_type='device.updated'": 1, "SELECT COUNT(*) FROM sessions": 0} {
		got, err := countRows(ctx, f.store.db, query)
		if err != nil || got != want {
			t.Fatalf("%s got %d want %d: %v", query, got, want, err)
		}
	}
	if _, _, _, err := f.store.ApproveDeviceLinkV3(ctx, f.link.ID, f.owner.Account.ID, f.owner.Device.ID, claimed.ClaimRequestHash, f.input.TranscriptHash, bytes.Repeat([]byte{7}, 32)); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("approval replacement: %v", err)
	}
	if _, err := f.store.DeviceLinkV3ForSource(ctx, f.link.ID, f.owner.Account.ID, device.ID); !errors.Is(err, ErrDeviceLinkInvalid) {
		t.Fatalf("recipient read source route: %v", err)
	}
	if err := f.store.CancelDeviceLinkV3(ctx, f.link.ID, f.owner.Account.ID, f.owner.Device.ID); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("approved link labelled cancelled: %v", err)
	}
}

func TestDeviceLinkV3StatusCannotCreateASession(t *testing.T) {
	f := newV3Fixture(t)
	ctx := context.Background()
	claimed := f.claim(t)
	if _, _, err := f.store.CompleteDeviceLinkV3(ctx, f.link.ID, f.input.ClaimTokenHash, claimed.ClaimRequestHash, f.input.InitialSessionTokenHash, f.input.TranscriptHash); !errors.Is(err, ErrDeviceLinkNotReady) {
		t.Fatalf("unapproved completion: %v", err)
	}
	f.approve(t)
	for range 3 {
		if _, err := f.store.DeviceLinkV3ForClaim(ctx, f.link.ID, f.input.ClaimTokenHash); err != nil {
			t.Fatal(err)
		}
	}
	count, err := countRows(ctx, f.store.db, "SELECT COUNT(*) FROM sessions")
	if err != nil || count != 0 {
		t.Fatalf("poll minted sessions: %d %v", count, err)
	}
}

func TestDeviceLinkV3LostCompletionResponseAndConcurrentRetry(t *testing.T) {
	f := newV3Fixture(t)
	ctx := context.Background()
	approved := f.approve(t)
	var wg sync.WaitGroup
	receipts := make(chan DeviceLinkV3Completion, 8)
	failures := make(chan error, 8)
	for range 8 {
		wg.Go(func() {
			receipt, _, err := f.store.CompleteDeviceLinkV3(ctx, f.link.ID, f.input.ClaimTokenHash, approved.ClaimRequestHash, f.input.InitialSessionTokenHash, f.input.TranscriptHash)
			if err != nil {
				failures <- err
			} else {
				receipts <- receipt
			}
		})
	}
	wg.Wait()
	close(receipts)
	close(failures)
	for err := range failures {
		t.Fatal(err)
	}
	var first *DeviceLinkV3Completion
	for receipt := range receipts {
		if first == nil {
			copy := receipt
			first = &copy
		} else if !reflect.DeepEqual(*first, receipt) {
			t.Fatal("completion receipt changed on retry")
		}
	}
	count, err := countRows(ctx, f.store.db, "SELECT COUNT(*) FROM sessions")
	if err != nil || count != 1 {
		t.Fatalf("completion minted %d sessions: %v", count, err)
	}
	principal, err := f.store.PrincipalByTokenHash(ctx, f.input.InitialSessionTokenHash)
	if err != nil || principal.DeviceID != f.reservation.DeviceID {
		t.Fatalf("precommitted token not active: %v", err)
	}
	public, _ := json.Marshal(first)
	for _, secret := range []string{f.claimToken, f.deviceSecret, f.sessionToken} {
		if bytes.Contains(public, []byte(secret)) {
			t.Fatal("receipt disclosed plaintext credential")
		}
	}
}

func TestDeviceLinkV3CompletionNeverResurrectsAnUnavailableSession(t *testing.T) {
	for _, condition := range []string{"logout", "rotation-grace", "idle", "expiry", "absolute"} {
		t.Run(condition, func(t *testing.T) {
			f := newV3Fixture(t)
			ctx := context.Background()
			receipt := f.complete(t)
			switch condition {
			case "logout":
				_, _ = f.store.db.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash=?`, f.input.InitialSessionTokenHash)
			case "rotation-grace":
				if err := f.store.RotateSession(ctx, f.input.InitialSessionTokenHash, newTokenHash(t)); err != nil {
					t.Fatal(err)
				}
				if _, err := f.store.PrincipalByTokenHash(ctx, f.input.InitialSessionTokenHash); err != nil {
					t.Fatalf("fixture has no active alias grace: %v", err)
				}
			case "idle":
				_, _ = f.store.db.ExecContext(ctx, `UPDATE sessions SET last_used_at=? WHERE token_hash=?`, formatTime(time.Now().UTC().Add(-f.store.sessions.idle-time.Second)), f.input.InitialSessionTokenHash)
			case "expiry":
				_, _ = f.store.db.ExecContext(ctx, `UPDATE sessions SET expires_at=? WHERE token_hash=?`, formatTime(time.Now().UTC().Add(-time.Second)), f.input.InitialSessionTokenHash)
			case "absolute":
				_, _ = f.store.db.ExecContext(ctx, `UPDATE sessions SET absolute_expires_at=? WHERE token_hash=?`, formatTime(time.Now().UTC().Add(-time.Second)), f.input.InitialSessionTokenHash)
			}
			before, err := countRows(ctx, f.store.db, "SELECT COUNT(*) FROM sessions")
			if err != nil {
				t.Fatal(err)
			}
			if _, _, err := f.store.CompleteDeviceLinkV3(ctx, f.link.ID, f.input.ClaimTokenHash, receipt.ClaimRequestHash, f.input.InitialSessionTokenHash, f.input.TranscriptHash); !errors.Is(err, ErrDeviceLinkSessionUnavailable) {
				t.Fatalf("unavailable session revived: %v", err)
			}
			after, err := countRows(ctx, f.store.db, "SELECT COUNT(*) FROM sessions")
			if err != nil || after != before {
				t.Fatalf("retry changed session rows: %d -> %d %v", before, after, err)
			}
		})
	}
}

func TestDeviceLinkV3CompletionRetryDoesNotRefreshOrFollowAliases(t *testing.T) {
	f := newV3Fixture(t)
	ctx := context.Background()
	first := f.complete(t)
	var before string
	query := `SELECT expires_at||last_used_at||recent_auth_at||absolute_expires_at FROM sessions WHERE token_hash=?`
	if err := f.store.db.QueryRowContext(ctx, query, f.input.InitialSessionTokenHash).Scan(&before); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.db.ExecContext(ctx, `UPDATE device_links_v3 SET expires_at=? WHERE id=?`, formatTime(time.Now().UTC().Add(-time.Minute)), f.link.ID); err != nil {
		t.Fatal(err)
	}
	second, _, err := f.store.CompleteDeviceLinkV3(ctx, f.link.ID, f.input.ClaimTokenHash, first.ClaimRequestHash, f.input.InitialSessionTokenHash, f.input.TranscriptHash)
	if err != nil || !reflect.DeepEqual(first, second) {
		t.Fatalf("lost-response receipt unavailable after claim window: %v", err)
	}
	var after string
	if err := f.store.db.QueryRowContext(ctx, query, f.input.InitialSessionTokenHash).Scan(&after); err != nil || after != before {
		t.Fatalf("completion extended authentication: %v", err)
	}
}

func TestDeviceLinkV3ExpiryCancelAndRevocation(t *testing.T) {
	t.Run("cancel-before-approval", func(t *testing.T) {
		f := newV3Fixture(t)
		ctx := context.Background()
		f.claim(t)
		for range 2 {
			if err := f.store.CancelDeviceLinkV3(ctx, f.link.ID, f.owner.Account.ID, f.owner.Device.ID); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := f.store.CreateDeviceLinkV3(ctx, f.owner.Account.ID, f.owner.Device.ID, f.link.Code, f.link.ServerOrigin, 0); !errors.Is(err, ErrDeviceLinkInvalid) {
			t.Fatalf("cancelled locator reused: %v", err)
		}
		if _, err := f.store.DeviceLinkV3ForClaim(ctx, f.link.ID, f.input.ClaimTokenHash); !errors.Is(err, ErrDeviceLinkInvalid) {
			t.Fatalf("cancelled credential active: %v", err)
		}
	})
	t.Run("first-completion-expired", func(t *testing.T) {
		f := newV3Fixture(t)
		ctx := context.Background()
		approved := f.approve(t)
		_, err := f.store.db.ExecContext(ctx, `UPDATE device_links_v3 SET expires_at=? WHERE id=?`, formatTime(time.Now().UTC().Add(-time.Second)), f.link.ID)
		if err != nil {
			t.Fatal(err)
		}
		if _, _, err := f.store.CompleteDeviceLinkV3(ctx, f.link.ID, f.input.ClaimTokenHash, approved.ClaimRequestHash, f.input.InitialSessionTokenHash, f.input.TranscriptHash); !errors.Is(err, ErrDeviceLinkInvalid) {
			t.Fatalf("expired first completion accepted: %v", err)
		}
	})
	for _, target := range []string{"source", "recipient"} {
		t.Run("revoked-"+target, func(t *testing.T) {
			f := newV3Fixture(t)
			ctx := context.Background()
			receipt := f.complete(t)
			deviceID := f.owner.Device.ID
			if target == "recipient" {
				deviceID = f.reservation.DeviceID
			}
			if err := f.store.RevokeDevice(ctx, f.owner.Account.ID, deviceID); err != nil {
				t.Fatal(err)
			}
			if _, _, err := f.store.CompleteDeviceLinkV3(ctx, f.link.ID, f.input.ClaimTokenHash, receipt.ClaimRequestHash, f.input.InitialSessionTokenHash, f.input.TranscriptHash); !errors.Is(err, ErrDeviceLinkInvalid) {
				t.Fatalf("revoked context active: %v", err)
			}
			count, err := countRows(ctx, f.store.db, `SELECT COUNT(*) FROM device_links_v3 WHERE id=?`, f.link.ID)
			if err != nil || count != 0 {
				t.Fatalf("revocation left context: %d %v", count, err)
			}
		})
	}
}

func TestDeviceLinkV3AndV2SharePendingAdmissionLimit(t *testing.T) {
	f := newV3Fixture(t)
	ctx := context.Background()
	if _, err := f.store.CreateDeviceLink(ctx, f.owner.Account.ID, f.owner.Device.ID, time.Minute, testLinkLocator(t)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.CreateDeviceLinkV3(ctx, f.owner.Account.ID, f.owner.Device.ID, testLinkLocator(t), f.link.ServerOrigin, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.CreateDeviceLink(ctx, f.owner.Account.ID, f.owner.Device.ID, time.Minute, testLinkLocator(t)); !errors.Is(err, ErrDeviceLinkLimit) {
		t.Fatalf("v2 bypassed mixed limit: %v", err)
	}
	if _, err := f.store.CreateDeviceLinkV3(ctx, f.owner.Account.ID, f.owner.Device.ID, testLinkLocator(t), f.link.ServerOrigin, 0); !errors.Is(err, ErrDeviceLinkLimit) {
		t.Fatalf("v3 bypassed mixed limit: %v", err)
	}
}

func TestDeviceLinkV3AccountDeletionAndRetentionRemoveEnrollmentContext(t *testing.T) {
	t.Run("account-deletion", func(t *testing.T) {
		f := newV3Fixture(t)
		ctx := context.Background()
		f.complete(t)
		// The last-owner safeguard is covered elsewhere; make this isolated
		// fixture an ordinary deletable account to exercise privacy cleanup.
		if _, err := f.store.db.ExecContext(ctx, `UPDATE accounts SET role='member' WHERE id=?`, f.owner.Account.ID); err != nil {
			t.Fatal(err)
		}
		if err := f.store.DeleteAccount(ctx, f.owner.Account.ID); err != nil {
			t.Fatal(err)
		}
		count, err := countRows(ctx, f.store.db, `SELECT COUNT(*) FROM device_links_v3 WHERE account_id=?`, f.owner.Account.ID)
		if err != nil || count != 0 {
			t.Fatalf("account deletion retained v3 context: %d %v", count, err)
		}
	})
	t.Run("bounded-expiry-cleanup", func(t *testing.T) {
		f := newV3Fixture(t)
		ctx := context.Background()
		old := formatTime(time.Now().UTC().Add(-OperationalRowRetention - time.Hour))
		if _, err := f.store.db.ExecContext(ctx, `UPDATE device_links_v3 SET expires_at=? WHERE id=?`, old, f.link.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := f.store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
		count, err := countRows(ctx, f.store.db, `SELECT COUNT(*) FROM device_links_v3 WHERE id=?`, f.link.ID)
		if err != nil || count != 0 {
			t.Fatalf("expired v3 context retained: %d %v", count, err)
		}
	})
	t.Run("transfer-window-is-not-claim-window", func(t *testing.T) {
		f := newV3Fixture(t)
		ctx := context.Background()
		f.complete(t)
		old := formatTime(time.Now().UTC().Add(-OperationalRowRetention - time.Hour))
		if _, err := f.store.db.ExecContext(ctx, `UPDATE device_links_v3 SET expires_at=? WHERE id=?`, old, f.link.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := f.store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
		if _, err := f.store.DeviceLinkV3ForClaim(ctx, f.link.ID, f.input.ClaimTokenHash); err != nil {
			t.Fatalf("claim TTL destroyed transfer context: %v", err)
		}
	})
}
