package c7vector

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"private-messenger/server/internal/storage"
)

// syncVector is testing/vectors/c7-sync-v1.json: one whole history_sync as
// sent, made by testing/vectors/c7-sync-v1.py. Rust and Dart check it too.
type syncVector struct {
	Inputs struct {
		Community    string `json:"community_id"`
		Conversation string `json:"conversation_id"`
		Sender       string `json:"sender_device_id"`
		Action       string `json:"action_id"`
		MessageEpoch uint64 `json:"message_epoch"`
		BodyKey      string `json:"body_key_hex"`
		Channels     []struct {
			ID        string `json:"channel_id"`
			Key       string `json:"key_hex"`
			SlotKey   string `json:"slot_key_hex"`
			SlotNonce string `json:"slot_nonce_hex"`
			SlotPlain string `json:"slot_plain_hex"`
		} `json:"channels"`
	} `json:"inputs"`
	Outputs struct {
		PublicKey    string `json:"signing_public_key_hex"`
		AAD          string `json:"body_aad_hex"`
		VAP1         string `json:"body0_padded_vap1_hex"`
		SignedFields string `json:"post_signed_fields_hex"`
		Signature    string `json:"post_signature_hex"`
		Sealed       string `json:"sealed_body_hex"`
		SealedSHA256 string `json:"sealed_body_sha256_hex"`
		Body0Length  int    `json:"body0_sealed_length"`
		Length       int    `json:"sealed_body_length"`
	} `json:"outputs"`
}

func TestHistorySyncVector(t *testing.T) {
	var v syncVector
	load(t, "c7-sync-v1.json", &v)
	in, out := v.Inputs, v.Outputs
	sealed := unhex(t, out.Sealed)
	n := len(in.Channels)
	padded := 256 * ((512 + 128*n + 255) / 256)
	if len(sealed) != out.Length || len(sealed) != padded+124+700*n {
		t.Fatal("history_sync length")
	}
	sum := sha256.Sum256(sealed)
	if hex.EncodeToString(sum[:]) != out.SealedSHA256 {
		t.Fatal("reference hash")
	}
	// The server takes it as a group-level body only (no channel_id).
	if !storage.C7BodySizeValid(len(sealed), true) || storage.C7BodySizeValid(len(sealed), false) {
		t.Fatal("server size rule")
	}

	// body0: sig | padded VAP1 under the body key, group-level aad.
	aad := concat(lp(in.Conversation), lp(""), lp(in.Sender), lp(in.Action))
	if hex.EncodeToString(aad) != out.AAD {
		t.Fatal("aad")
	}
	split := padded + 124
	if split != out.Body0Length {
		t.Fatal("body0 length")
	}
	body0 := open(t, unhex(t, in.BodyKey), aad, sealed[:split])
	sig, vap1 := body0[:64], body0[64:]
	if hex.EncodeToString(vap1) != out.VAP1 || !bytes.HasPrefix(vap1, []byte("VAP1")) {
		t.Fatal("body0 VAP1")
	}
	vapHash := sha256.Sum256(vap1)
	fields := concat(lp(in.Community), lp(""), lp(in.Action), lp(in.Conversation), u64(in.MessageEpoch),
		lp(in.Sender), u64(0), vapHash[:])
	if hex.EncodeToString(fields) != out.SignedFields || hex.EncodeToString(sig) != out.Signature {
		t.Fatal("post signature fields")
	}
	if !ed25519.Verify(unhex(t, out.PublicKey), concat([]byte("veritra-c7-post-sig-v1"), fields), sig) {
		t.Fatal("post signature")
	}

	// Each slot opens under HKDF(key_c, slot label, its own binding), and Go's
	// own seal with the stated nonce gives the same 700 bytes.
	for i, c := range in.Channels {
		slot := sealed[split+700*i : split+700*(i+1)]
		info := concat(lp(in.Community), lp(c.ID), lp(in.Sender), lp(in.Action))
		slotKey := derive(t, unhex(t, c.Key), "veritra-c7-slot-v1", info)
		if hex.EncodeToString(slotKey) != c.SlotKey {
			t.Fatalf("slot key %d", i)
		}
		plain := unhex(t, c.SlotPlain)
		if len(plain) != 640 || !bytes.Equal(open(t, slotKey, aad, slot), plain) {
			t.Fatalf("slot %d", i)
		}
		if !bytes.Equal(seal(t, slotKey, unhex(t, c.SlotNonce), aad, plain), slot) {
			t.Fatalf("slot bytes %d", i)
		}
		entry := plain[512:]
		if bytes.Equal(entry, make([]byte, 128)) {
			if !bytes.Equal(plain[:512], make([]byte, 512)) {
				t.Fatalf("a zero entry with a head %d", i)
			}
			continue
		}
		// The entry commits to key_c: the key this slot hands over.
		commit := sha256.Sum256(append([]byte("veritra-c7-chk-v1"), unhex(t, c.Key)...))
		if !bytes.Equal(entry[8:40], commit[:]) || len(bytes.TrimRight(entry[80:], "\x00")) != 0 {
			t.Fatalf("generation entry %d", i)
		}
	}
}
