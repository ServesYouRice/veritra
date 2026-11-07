package storage

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
)

// The binding (D90). The store keeps what the creating device bound the
// invitation to and returns it with the preview and the answer to a request;
// the tag itself can only be checked by someone holding the link secret.

func TestInviteBindingIsStoredAndReturned(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	tag := strings.Repeat("5f", 32)
	if _, err := f.store.CreateMembershipInvite(ctx, CreateMembershipInviteInput{Target: f.groupTarget(), CreatedBy: f.admin.Account.ID, CreatedByDeviceID: f.admin.Device.ID, SigningKey: f.admin.Device.SigningKey, BindingTag: tag, Locator: testLocator(1), MaxUses: 2, ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	want := domain.InviteBinding{TargetKind: domain.InviteTargetGroup, TargetID: f.group.ID, InviterAccountID: f.admin.Account.ID, InviterDeviceID: f.admin.Device.ID, InviterSigningKey: f.admin.Device.SigningKey, Tag: tag}
	same := func(got domain.InviteBinding) bool {
		return got.TargetKind == want.TargetKind && got.TargetID == want.TargetID && got.InviterAccountID == want.InviterAccountID &&
			got.InviterDeviceID == want.InviterDeviceID && string(got.InviterSigningKey) == string(want.InviterSigningKey) && got.Tag == want.Tag
	}
	preview, err := f.store.PreviewMembershipInvite(ctx, alice.Account.ID, testLocator(1))
	if err != nil || !same(preview.Binding) {
		t.Fatalf("preview binding = %+v err=%v, want %+v", preview.Binding, err, want)
	}
	request, created, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(1))
	if err != nil || !created || request.Binding == nil || !same(*request.Binding) {
		t.Fatalf("request = %+v created=%v err=%v", request, created, err)
	}
	again, created, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(1))
	if err != nil || created || again.Binding == nil || !same(*again.Binding) {
		t.Fatalf("repeated request = %+v created=%v err=%v", again, created, err)
	}
}

func TestInviteBindingMustMatchTheCreatingDevice(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	otherKey := append([]byte(nil), f.admin.Device.SigningKey...)
	otherKey[0] ^= 1
	base := CreateMembershipInviteInput{Target: f.groupTarget(), CreatedBy: f.admin.Account.ID, CreatedByDeviceID: f.admin.Device.ID, SigningKey: f.admin.Device.SigningKey, BindingTag: testBindingTag, Locator: testLocator(2), MaxUses: 1, ExpiresAt: time.Now().Add(time.Hour)}
	mutations := map[string]func(*CreateMembershipInviteInput){
		"another key than the device's": func(in *CreateMembershipInviteInput) { in.SigningKey = otherKey },
		"a short key":                   func(in *CreateMembershipInviteInput) { in.SigningKey = in.SigningKey[:31] },
		"no key":                        func(in *CreateMembershipInviteInput) { in.SigningKey = nil },
		"another account's device": func(in *CreateMembershipInviteInput) {
			in.CreatedByDeviceID = f.owner.Device.ID
			in.SigningKey = f.owner.Device.SigningKey
		},
		"an unknown device":               func(in *CreateMembershipInviteInput) { in.CreatedByDeviceID = "dev_unknown" },
		"no device":                       func(in *CreateMembershipInviteInput) { in.CreatedByDeviceID = "" },
		"no tag":                          func(in *CreateMembershipInviteInput) { in.BindingTag = "" },
		"a tag that is not 64 hex digits": func(in *CreateMembershipInviteInput) { in.BindingTag = "xyz" },
		"an upper case tag":               func(in *CreateMembershipInviteInput) { in.BindingTag = strings.ToUpper(testBindingTag) },
		"a tag of the wrong length":       func(in *CreateMembershipInviteInput) { in.BindingTag = testBindingTag[:62] },
	}
	for name, mutate := range mutations {
		input := base
		mutate(&input)
		if _, err := f.store.CreateMembershipInvite(ctx, input); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("%s: %v", name, err)
		}
	}
	if _, err := f.store.CreateMembershipInvite(ctx, base); err != nil {
		t.Fatalf("the unmodified input: %v", err)
	}
}

func TestInviteStopsWorkingWhenItsDeviceIsRevoked(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob := f.people[0], f.people[1]
	f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(3), 5)
	pending, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(3))
	if err != nil {
		t.Fatal(err)
	}
	if err := f.store.RevokeDevice(ctx, f.admin.Account.ID, f.admin.Device.ID); err != nil {
		t.Fatalf("revoke device: %v", err)
	}
	if _, err := f.store.PreviewMembershipInvite(ctx, bob.Account.ID, testLocator(3)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("preview after the device was revoked: %v", err)
	}
	if _, _, err := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(3)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("request after the device was revoked: %v", err)
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, pending.ID, true); err == nil {
		t.Fatal("approved a request through an invitation whose device was revoked")
	}
	listed, err := f.store.ListJoinRequests(ctx, f.groupTarget(), f.owner.Account.ID)
	if err != nil || len(listed) != 0 {
		t.Fatalf("listed = %+v err=%v", listed, err)
	}
}

// The tag is HMAC-SHA256 keyed from the link secret; the app computes it
// (mobile/test/membership_invite_link_test.dart pins the same vector) and the
// server only stores it. This builds the same bytes independently so a change
// to the layout on either side fails a test.
func TestInviteBindingTagVector(t *testing.T) {
	secret := make([]byte, 32)
	signingKey := make([]byte, 32)
	for i := range secret {
		secret[i] = byte(i)
		signingKey[i] = byte(0x40 + i)
	}
	lp := func(value []byte) []byte {
		return append([]byte{byte(len(value) >> 8), byte(len(value))}, value...)
	}
	key := sha256.Sum256(append([]byte("veritra/membership-invite/v1/binding-key\x00"), secret...))
	message := []byte("veritra/membership-invite/v1/binding\x00")
	for _, field := range [][]byte{[]byte("https://chat.example.org"), []byte("group"), []byte("conv_1"), []byte("acct_alice"), []byte("dev_alice"), signingKey} {
		message = append(message, lp(field)...)
	}
	mac := hmac.New(sha256.New, key[:])
	mac.Write(message)
	if got := hex.EncodeToString(key[:]); got != "ba25a5304afe2bcacf0f425dd3775734ffb9b40ddfdb7d4505b267b5e7c30349" {
		t.Fatalf("binding key = %s", got)
	}
	const want = "fc9063055daea1729609a3cd9a4916b4fcb78e2477c6f16c9709c2ff1b108cf7"
	if got := hex.EncodeToString(mac.Sum(nil)); got != want {
		t.Fatalf("tag = %s, want %s", got, want)
	}
	if !validLocator(want) {
		t.Fatal("a real tag is refused by the shape check")
	}
}
