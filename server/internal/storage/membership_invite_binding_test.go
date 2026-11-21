package storage

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
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
	if _, err := f.store.CreateMembershipInvite(ctx, CreateMembershipInviteInput{Target: f.groupTarget(), AnchorGroupID: f.group.ID, CreatedBy: f.admin.Account.ID, CreatedByDeviceID: f.admin.Device.ID, SigningKey: f.admin.Device.SigningKey, BindingTag: tag, BindingSignature: testBindingSignature, Locator: testLocator(1), MaxUses: 2, ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	want := domain.InviteBinding{TargetKind: domain.InviteTargetGroup, TargetID: f.group.ID, AnchorGroupID: f.group.ID, InviterAccountID: f.admin.Account.ID, InviterDeviceID: f.admin.Device.ID, InviterSigningKey: f.admin.Device.SigningKey, Tag: tag, Signature: testBindingSignature}
	same := func(got domain.InviteBinding) bool {
		return got.TargetKind == want.TargetKind && got.TargetID == want.TargetID && got.AnchorGroupID == want.AnchorGroupID && got.InviterAccountID == want.InviterAccountID &&
			got.InviterDeviceID == want.InviterDeviceID && string(got.InviterSigningKey) == string(want.InviterSigningKey) && got.Tag == want.Tag && bytes.Equal(got.Signature, want.Signature)
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
	base := CreateMembershipInviteInput{Target: f.groupTarget(), AnchorGroupID: f.group.ID, CreatedBy: f.admin.Account.ID, CreatedByDeviceID: f.admin.Device.ID, SigningKey: f.admin.Device.SigningKey, BindingTag: testBindingTag, BindingSignature: testBindingSignature, Locator: testLocator(2), MaxUses: 1, ExpiresAt: time.Now().Add(time.Hour)}
	mutations := map[string]func(*CreateMembershipInviteInput){
		"another key than the device's": func(in *CreateMembershipInviteInput) { in.SigningKey = otherKey },
		"a short key":                   func(in *CreateMembershipInviteInput) { in.SigningKey = in.SigningKey[:31] },
		"no key":                        func(in *CreateMembershipInviteInput) { in.SigningKey = nil },
		"another account's device": func(in *CreateMembershipInviteInput) {
			in.CreatedByDeviceID = f.owner.Device.ID
			in.SigningKey = f.owner.Device.SigningKey
		},
		"an unknown device": func(in *CreateMembershipInviteInput) { in.CreatedByDeviceID = "dev_unknown" },
		"no device":         func(in *CreateMembershipInviteInput) { in.CreatedByDeviceID = "" },
		"no signature":      func(in *CreateMembershipInviteInput) { in.BindingSignature = nil },
		"a short signature": func(in *CreateMembershipInviteInput) { in.BindingSignature = in.BindingSignature[:63] },
		"a long signature": func(in *CreateMembershipInviteInput) {
			in.BindingSignature = append(append([]byte(nil), in.BindingSignature...), 0)
		},
		"no tag":                          func(in *CreateMembershipInviteInput) { in.BindingTag = "" },
		"a tag that is not 64 hex digits": func(in *CreateMembershipInviteInput) { in.BindingTag = "xyz" },
		"an upper case tag":               func(in *CreateMembershipInviteInput) { in.BindingTag = strings.ToUpper(testBindingTag) },
		"a tag of the wrong length":       func(in *CreateMembershipInviteInput) { in.BindingTag = testBindingTag[:62] },
		// v3: the signed anchor must be the group itself.
		"no anchor":                     func(in *CreateMembershipInviteInput) { in.AnchorGroupID = "" },
		"another conversation's anchor": func(in *CreateMembershipInviteInput) { in.AnchorGroupID = f.conv.ID },
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

// A row made before migration 0066 has no signature. The store returns it as
// it is (an empty signature) and the v2 app refuses it; nothing rewrites it.
func TestInviteWithoutSignatureIsReturnedEmpty(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(7), 1)
	if _, err := f.store.db.ExecContext(ctx, `UPDATE membership_invites SET binding_signature = NULL`); err != nil {
		t.Fatal(err)
	}
	preview, err := f.store.PreviewMembershipInvite(ctx, alice.Account.ID, testLocator(7))
	if err != nil || len(preview.Binding.Signature) != 0 {
		t.Fatalf("preview = %+v err=%v", preview.Binding, err)
	}
	if _, err := f.store.db.ExecContext(ctx, `UPDATE membership_invites SET binding_signature = ?`, []byte{1, 2, 3}); err == nil {
		t.Fatal("the schema accepted a signature of the wrong length")
	}
}

// The v2 signature is Ed25519 over a domain label and the lp() fields; the app
// signs through the ABI 13 call and verifies through the strict one. This
// rebuilds the bytes with the standard library from
// testing/vectors/invite-binding-v2.json, which the Rust and Dart tests read
// as well, so a change to the layout on any side fails a test. Go needs no
// new dependency: crypto/ed25519 is deterministic for a fixed seed.
func TestInviteBindingV2Vector(t *testing.T) {
	raw, err := os.ReadFile("../../../testing/vectors/invite-binding-v2.json")
	if err != nil {
		t.Fatal(err)
	}
	var vector struct {
		Inputs struct {
			Origin           string `json:"origin"`
			SecretHex        string `json:"secret_hex"`
			SigningSeedHex   string `json:"signing_seed_hex"`
			TargetKind       string `json:"target_kind"`
			TargetID         string `json:"target_id"`
			InviterAccountID string `json:"inviter_account_id"`
			InviterDeviceID  string `json:"inviter_device_id"`
		} `json:"inputs"`
		Outputs struct {
			SigningPublicKeyHex string `json:"signing_public_key_hex"`
			Locator             string `json:"locator"`
			KeyCommitmentHex    string `json:"key_commitment_hex"`
			SignedMessageHex    string `json:"signed_message_hex"`
			SignatureHex        string `json:"signature_hex"`
			LinkFragment        string `json:"link_fragment"`
		} `json:"outputs"`
	}
	if err := json.Unmarshal(raw, &vector); err != nil {
		t.Fatal(err)
	}
	secret, err := hex.DecodeString(vector.Inputs.SecretHex)
	if err != nil {
		t.Fatal(err)
	}
	seed, err := hex.DecodeString(vector.Inputs.SigningSeedHex)
	if err != nil {
		t.Fatal(err)
	}
	private := ed25519.NewKeyFromSeed(seed)
	public := private.Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(public); got != vector.Outputs.SigningPublicKeyHex {
		t.Fatalf("public key = %s", got)
	}
	locatorSum := sha256.Sum256(append([]byte("veritra/membership-invite/v1/locator\x00"), secret...))
	locator := hex.EncodeToString(locatorSum[:])
	if locator != vector.Outputs.Locator {
		t.Fatalf("locator = %s", locator)
	}
	commitSum := sha256.Sum256(append([]byte("veritra/membership-invite/v2/key-commit\x00"), public...))
	if got := hex.EncodeToString(commitSum[:16]); got != vector.Outputs.KeyCommitmentHex {
		t.Fatalf("key commitment = %s", got)
	}
	fragment := "v2." + base64.RawURLEncoding.EncodeToString(secret) + "." + base64.RawURLEncoding.EncodeToString(commitSum[:16])
	if fragment != vector.Outputs.LinkFragment {
		t.Fatalf("fragment = %s", fragment)
	}
	lp := func(value []byte) []byte {
		return append([]byte{byte(len(value) >> 8), byte(len(value))}, value...)
	}
	var message []byte
	for _, field := range [][]byte{[]byte(vector.Inputs.Origin), []byte(vector.Inputs.TargetKind), []byte(vector.Inputs.TargetID), []byte(vector.Inputs.InviterAccountID), []byte(vector.Inputs.InviterDeviceID), public, []byte(locator)} {
		message = append(message, lp(field)...)
	}
	if got := hex.EncodeToString(message); got != vector.Outputs.SignedMessageHex {
		t.Fatalf("message = %s", got)
	}
	signed := append([]byte("veritra-invite-binding-v2"), message...)
	signature := ed25519.Sign(private, signed)
	if got := hex.EncodeToString(signature); got != vector.Outputs.SignatureHex {
		t.Fatalf("signature = %s", got)
	}
	if !ed25519.Verify(public, signed, signature) || ed25519.Verify(public, append([]byte("veritra-c7-history-v1"), message...), signature) {
		t.Fatal("the signature must verify in its own domain only")
	}
	if len(signature) != inviteSignatureLength {
		t.Fatalf("signature length %d is not the stored length", len(signature))
	}
}

// v3 (2026-11-21): the binding carries the MLS group the invitation admits to.
// For a community with the C0 layout that is the shared conversation, which
// the server already holds; it checks the app's value against it and returns
// its own on the preview and the request answer. Nothing new is stored.
func TestCommunityInviteAnchorIsTheSharedGroup(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	target := MembershipTarget{Kind: domain.InviteTargetCommunity, ID: f.community.ID}
	base := CreateMembershipInviteInput{Target: target, AnchorGroupID: f.shared, CreatedBy: f.owner.Account.ID, CreatedByDeviceID: f.owner.Device.ID, SigningKey: f.owner.Device.SigningKey, BindingTag: testBindingTag, BindingSignature: testBindingSignature, Locator: testLocator(9), MaxUses: 1, ExpiresAt: time.Now().Add(time.Hour)}
	for name, anchor := range map[string]string{
		"no anchor":                  "",
		"the community id":           f.community.ID,
		"a private channel's group":  f.privateConv,
		"an unknown conversation id": "conv_other",
	} {
		input := base
		input.AnchorGroupID = anchor
		if _, err := f.store.CreateMembershipInvite(ctx, input); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("%s: %v", name, err)
		}
	}
	if _, err := f.store.CreateMembershipInvite(ctx, base); err != nil {
		t.Fatalf("the shared group: %v", err)
	}
	preview, err := f.store.PreviewMembershipInvite(ctx, f.outsider.Account.ID, testLocator(9))
	if err != nil || preview.Binding.AnchorGroupID != f.shared || preview.Binding.TargetID != f.community.ID {
		t.Fatalf("preview binding = %+v err=%v", preview.Binding, err)
	}
	request, _, err := f.store.RequestToJoin(ctx, f.outsider.Account.ID, testLocator(9))
	if err != nil || request.Binding == nil || request.Binding.AnchorGroupID != f.shared {
		t.Fatalf("request = %+v err=%v", request, err)
	}
	// No column was added: the anchor is derived, never stored.
	columns := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM pragma_table_info('membership_invites') WHERE name LIKE '%anchor%'`)
	if columns != 0 {
		t.Fatalf("membership_invites has %d anchor columns", columns)
	}
}

// A legacy community (switch off) has no shared group, so no anchor: the
// server returns an empty one, which the v3 app refuses, and refuses any
// anchor an app names for it.
func TestLegacyCommunityInviteHasNoAnchor(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	base := CreateMembershipInviteInput{Target: f.communityTarget(), CreatedBy: f.admin.Account.ID, CreatedByDeviceID: f.admin.Device.ID, SigningKey: f.admin.Device.SigningKey, BindingTag: testBindingTag, BindingSignature: testBindingSignature, Locator: testLocator(10), MaxUses: 1, ExpiresAt: time.Now().Add(time.Hour)}
	named := base
	named.AnchorGroupID = f.conv.ID
	if _, err := f.store.CreateMembershipInvite(ctx, named); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("a legacy community accepted an anchor: %v", err)
	}
	if _, err := f.store.CreateMembershipInvite(ctx, base); err != nil {
		t.Fatal(err)
	}
	preview, err := f.store.PreviewMembershipInvite(ctx, f.people[0].Account.ID, testLocator(10))
	if err != nil || preview.Binding.AnchorGroupID != "" {
		t.Fatalf("preview binding = %+v err=%v", preview.Binding, err)
	}
}

// The v3 layout, rebuilt with the standard library from
// testing/vectors/invite-binding-v3.json, which the Dart tests read too.
// It also pins that a v2 signature and a v3 signature never stand for each
// other.
func TestInviteBindingV3Vector(t *testing.T) {
	raw, err := os.ReadFile("../../../testing/vectors/invite-binding-v3.json")
	if err != nil {
		t.Fatal(err)
	}
	var vector struct {
		Inputs struct {
			Origin           string `json:"origin"`
			SecretHex        string `json:"secret_hex"`
			SigningSeedHex   string `json:"signing_seed_hex"`
			VersionField     string `json:"version_field"`
			TargetKind       string `json:"target_kind"`
			TargetID         string `json:"target_id"`
			AnchorGroupID    string `json:"anchor_group_id"`
			InviterAccountID string `json:"inviter_account_id"`
			InviterDeviceID  string `json:"inviter_device_id"`
		} `json:"inputs"`
		Outputs struct {
			SigningPublicKeyHex string `json:"signing_public_key_hex"`
			Locator             string `json:"locator"`
			KeyCommitmentHex    string `json:"key_commitment_hex"`
			Tag                 string `json:"tag"`
			SignedMessageHex    string `json:"signed_message_hex"`
			SignatureHex        string `json:"signature_hex"`
			LinkFragment        string `json:"link_fragment"`
		} `json:"outputs"`
	}
	if err := json.Unmarshal(raw, &vector); err != nil {
		t.Fatal(err)
	}
	in, out := vector.Inputs, vector.Outputs
	if in.VersionField != "veritra/membership-invite/v3" || in.AnchorGroupID == "" {
		t.Fatalf("vector inputs = %+v", in)
	}
	secret, err := hex.DecodeString(in.SecretHex)
	if err != nil {
		t.Fatal(err)
	}
	seed, err := hex.DecodeString(in.SigningSeedHex)
	if err != nil {
		t.Fatal(err)
	}
	private := ed25519.NewKeyFromSeed(seed)
	public := private.Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(public); got != out.SigningPublicKeyHex {
		t.Fatalf("public key = %s", got)
	}
	locatorSum := sha256.Sum256(append([]byte("veritra/membership-invite/v1/locator\x00"), secret...))
	locator := hex.EncodeToString(locatorSum[:])
	if locator != out.Locator {
		t.Fatalf("locator = %s", locator)
	}
	commitSum := sha256.Sum256(append([]byte("veritra/membership-invite/v2/key-commit\x00"), public...))
	if got := hex.EncodeToString(commitSum[:16]); got != out.KeyCommitmentHex {
		t.Fatalf("key commitment = %s", got)
	}
	if fragment := "v3." + base64.RawURLEncoding.EncodeToString(secret) + "." + base64.RawURLEncoding.EncodeToString(commitSum[:16]); fragment != out.LinkFragment {
		t.Fatalf("fragment = %s", fragment)
	}
	lp := func(value []byte) []byte {
		return append([]byte{byte(len(value) >> 8), byte(len(value))}, value...)
	}
	var fields []byte
	for _, field := range [][]byte{[]byte(in.VersionField), []byte(in.Origin), []byte(in.TargetKind), []byte(in.TargetID), []byte(in.AnchorGroupID), []byte(in.InviterAccountID), []byte(in.InviterDeviceID), public} {
		fields = append(fields, lp(field)...)
	}
	bindingKey := sha256.Sum256(append([]byte("veritra/membership-invite/v1/binding-key\x00"), secret...))
	mac := hmac.New(sha256.New, bindingKey[:])
	mac.Write(append([]byte("veritra/membership-invite/v3/binding\x00"), fields...))
	if got := hex.EncodeToString(mac.Sum(nil)); got != out.Tag || !validLocator(got) {
		t.Fatalf("tag = %s", got)
	}
	message := append(append([]byte(nil), fields...), lp([]byte(locator))...)
	if got := hex.EncodeToString(message); got != out.SignedMessageHex {
		t.Fatalf("message = %s", got)
	}
	signed := append([]byte("veritra-invite-binding-v2"), message...)
	signature := ed25519.Sign(private, signed)
	if got := hex.EncodeToString(signature); got != out.SignatureHex {
		t.Fatalf("signature = %s", got)
	}
	// The same device, link and fields laid out as v2 (no version field, no
	// anchor) give another message, so neither signature verifies as the
	// other: a server cannot downgrade a v3 binding or replay a v2 one.
	var v2 []byte
	for _, field := range [][]byte{[]byte(in.Origin), []byte(in.TargetKind), []byte(in.TargetID), []byte(in.InviterAccountID), []byte(in.InviterDeviceID), public, []byte(locator)} {
		v2 = append(v2, lp(field)...)
	}
	v2Signature := ed25519.Sign(private, append([]byte("veritra-invite-binding-v2"), v2...))
	if ed25519.Verify(public, signed, v2Signature) || ed25519.Verify(public, append([]byte("veritra-invite-binding-v2"), v2...), signature) {
		t.Fatal("a v2 and a v3 signature stand for each other")
	}
	// Another anchor (a replay into another group) is another message.
	var other []byte
	for _, field := range [][]byte{[]byte(in.VersionField), []byte(in.Origin), []byte(in.TargetKind), []byte(in.TargetID), []byte("conv_other"), []byte(in.InviterAccountID), []byte(in.InviterDeviceID), public, []byte(locator)} {
		other = append(other, lp(field)...)
	}
	if ed25519.Verify(public, append([]byte("veritra-invite-binding-v2"), other...), signature) {
		t.Fatal("the signature verifies for another anchor")
	}
}
