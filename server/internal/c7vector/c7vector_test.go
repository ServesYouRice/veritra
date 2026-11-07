package c7vector

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func load(t *testing.T, name string, into any) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", name))
	if err != nil {
		t.Fatalf("%s: %v (a missing vector fails; it never skips)", name, err)
	}
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func lp(s string) []byte {
	return append([]byte{byte(len(s) >> 8), byte(len(s))}, s...)
}

func u64(v uint64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, v)
	return b
}

func concat(parts ...[]byte) []byte { return bytes.Join(parts, nil) }

// derive is C7's HKDF-SHA256: salt = label, ikm = key, 32 bytes out.
func derive(t *testing.T, key []byte, label string, info []byte) []byte {
	t.Helper()
	out, err := hkdf.Key(sha256.New, key, []byte(label), string(info), 32)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

type primitives struct {
	Inputs  map[string]any `json:"inputs"`
	Outputs struct {
		BodyAAD         string `json:"body_aad_hex"`
		BodyKey         string `json:"body_key_hex"`
		ChkCommit       string `json:"chk_commit_hex"`
		Chk             string `json:"chk_hex"`
		ExporterContext string `json:"exporter_context_hex"`
		ExporterLabel   string `json:"exporter_label"`
		EntryHex        string `json:"generation_entry_hex"`
		ZeroEntryHex    string `json:"zero_generation_entry_hex"`
		Lengths         []struct {
			Channels        int `json:"channels"`
			Body0Padded     int `json:"body0_padded"`
			HistorySyncBody int `json:"history_sync_body"`
		} `json:"lengths"`
		PostSignature    string `json:"post_signature_hex"`
		PostSignedFields string `json:"post_signed_fields_hex"`
		CompactHex       string `json:"record_compact_hex"`
		FullHex          string `json:"record_full_hex"`
		MoveCompactHex   string `json:"record_move_compact_hex"`
		RecordHash       string `json:"record_hash_hex"`
		RecordSigned     string `json:"record_signed_fields_hex"`
		SealedBody       string `json:"sealed_body_hex"`
		PublicKey        string `json:"signing_public_key_hex"`
		Slot             string `json:"slot_hex"`
		SlotKey          string `json:"slot_key_hex"`
		SlotPlain        string `json:"slot_plain_hex"`
	} `json:"outputs"`
}

func str(m map[string]any, k string) string { return m[k].(string) }
func num(m map[string]any, k string) uint64 { return uint64(m[k].(float64)) }

// open is c7 open: kc | nonce | AES-256-GCM, with the commitment first.
func open(t *testing.T, key, aad, sealed []byte) []byte {
	t.Helper()
	kEnc := derive(t, key, "veritra-c7-enc-v1", nil)
	kc := derive(t, key, "veritra-c7-kc-v1", nil)
	if !bytes.Equal(sealed[:32], kc) {
		t.Fatal("key commitment mismatch")
	}
	block, err := aes.NewCipher(kEnc)
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := gcm.Open(nil, sealed[32:44], sealed[44:], aad)
	if err != nil {
		t.Fatal(err)
	}
	return plain
}

func seal(t *testing.T, key, nonce, aad, plain []byte) []byte {
	t.Helper()
	kEnc := derive(t, key, "veritra-c7-enc-v1", nil)
	kc := derive(t, key, "veritra-c7-kc-v1", nil)
	block, _ := aes.NewCipher(kEnc)
	gcm, _ := cipher.NewGCM(block)
	return concat(kc, nonce, gcm.Seal(nil, nonce, plain, aad))
}

func TestPrimitivesVectorReDerived(t *testing.T) {
	var v primitives
	load(t, "c7-primitives-v1.json", &v)
	in, out := v.Inputs, v.Outputs
	community, channel := str(in, "community_id"), str(in, "channel_id")
	sender, action := str(in, "sender_device_id"), str(in, "action_id")
	group, conversation := str(in, "group_id"), str(in, "conversation_id")
	epoch := num(in, "epoch")

	// Keys.
	chk := derive(t, unhex(t, str(in, "root_hex")), "veritra-c7-rekey-chk-v1", concat(lp(community), lp(channel)))
	if hex.EncodeToString(chk) != out.Chk {
		t.Fatal("chk")
	}
	commit := sha256.Sum256(append([]byte("veritra-c7-chk-v1"), chk...))
	if hex.EncodeToString(commit[:]) != out.ChkCommit {
		t.Fatal("chk_commit")
	}
	info := concat(lp(community), lp(channel), lp(sender), lp(action))
	bodyKey := derive(t, chk, "veritra-c7-post-v1", info)
	slotKey := derive(t, chk, "veritra-c7-slot-v1", info)
	if hex.EncodeToString(bodyKey) != out.BodyKey || hex.EncodeToString(slotKey) != out.SlotKey {
		t.Fatal("body or slot key")
	}

	// Exporter label and context.
	if out.ExporterLabel != "veritra-c7-rekey-v1" {
		t.Fatal("exporter label")
	}
	if hex.EncodeToString(concat(lp(group), u64(epoch))) != out.ExporterContext {
		t.Fatal("exporter context")
	}

	// A sealed body: layout, aad, and Go's own seal gives the same bytes.
	aad := concat(lp(conversation), lp(channel), lp(sender), lp(action))
	if hex.EncodeToString(aad) != out.BodyAAD {
		t.Fatal("body aad")
	}
	plain := unhex(t, str(in, "body_plaintext_hex"))
	sealed := unhex(t, out.SealedBody)
	if got := open(t, bodyKey, aad, sealed); !bytes.Equal(got, plain) {
		t.Fatal("body plaintext")
	}
	if !bytes.Equal(seal(t, bodyKey, unhex(t, str(in, "body_nonce_hex")), aad, plain), sealed) {
		t.Fatal("sealed body bytes")
	}
	if len(sealed) != len(plain)+60 {
		t.Fatal("seal overhead")
	}

	// Signature fields and verification, domain separated.
	pub := ed25519.NewKeyFromSeed(unhex(t, str(in, "signing_seed_hex"))).Public().(ed25519.PublicKey)
	if hex.EncodeToString(pub) != out.PublicKey {
		t.Fatal("public key")
	}
	vap1 := sha256.Sum256(unhex(t, str(in, "padded_vap1_hex")))
	fields := concat(lp(community), lp(channel), lp(action), lp(group), u64(epoch), lp(sender), u64(num(in, "generation")), vap1[:])
	if hex.EncodeToString(fields) != out.PostSignedFields {
		t.Fatal("post signed fields")
	}
	sig := unhex(t, out.PostSignature)
	if !ed25519.Verify(pub, concat([]byte("veritra-c7-post-sig-v1"), fields), sig) {
		t.Fatal("post signature")
	}
	if ed25519.Verify(pub, concat([]byte("veritra-c7-history-v1"), fields), sig) {
		t.Fatal("a post signature verified in the history domain")
	}

	// The full record: rebuild it from the inputs, check layout, hash, signature.
	prev := unhex(t, str(in, "prev_hex"))
	signed := concat(lp(community), lp(channel), binary.BigEndian.AppendUint32(nil, uint32(num(in, "seq"))), prev,
		[]byte{1, 1}, lp(group), u64(epoch), lp(group), u64(epoch), commit[:], lp(sender))
	if hex.EncodeToString(signed) != out.RecordSigned {
		t.Fatal("record signed fields")
	}
	full := unhex(t, out.FullHex)
	if len(full) != 512 || full[0] != 1 || !bytes.Equal(full[1:1+len(signed)], signed) {
		t.Fatal("record layout")
	}
	recSig := full[1+len(signed) : 1+len(signed)+64]
	if !ed25519.Verify(pub, concat([]byte("veritra-c7-history-v1"), signed), recSig) {
		t.Fatal("record signature")
	}
	if len(bytes.TrimRight(full[1+len(signed)+64:], "\x00")) != 0 {
		t.Fatal("record padding")
	}
	hash := sha256.Sum256(full)
	if hex.EncodeToString(hash[:]) != out.RecordHash {
		t.Fatal("record hash")
	}

	// The compact form: 143 bytes, and what it carries.
	compact := unhex(t, out.CompactHex)
	want := concat([]byte{1}, binary.BigEndian.AppendUint32(nil, uint32(num(in, "seq"))), prev, []byte{1, 1}, u64(epoch), chk, recSig)
	if !bytes.Equal(compact, want) || len(compact) != 143 {
		t.Fatal("compact record")
	}
	move := unhex(t, out.MoveCompactHex)
	oldGroup := str(in, "old_group_id")
	if len(move) != 143+2+len(oldGroup)+128 {
		t.Fatal("move compact length")
	}
	if !bytes.Equal(move[143:143+2+len(oldGroup)], lp(oldGroup)) {
		t.Fatal("move close group")
	}

	// The generation entry and the slot.
	prevChk := unhex(t, str(in, "previous_chk_hex"))
	entry := concat(u64(epoch), commit[:], u64(num(in, "previous_epoch")), prevChk)
	entry = append(entry, make([]byte, 128-len(entry))...)
	if hex.EncodeToString(entry) != out.EntryHex {
		t.Fatal("generation entry")
	}
	if out.ZeroEntryHex != hex.EncodeToString(make([]byte, 128)) {
		t.Fatal("zero entry")
	}
	slotPlain := concat(full, entry)
	if hex.EncodeToString(slotPlain) != out.SlotPlain {
		t.Fatal("slot plain")
	}
	slot := unhex(t, out.Slot)
	if len(slot) != 700 || !bytes.Equal(open(t, slotKey, aad, slot), slotPlain) {
		t.Fatal("slot")
	}
	if !bytes.Equal(seal(t, slotKey, unhex(t, str(in, "slot_nonce_hex")), aad, slotPlain), slot) {
		t.Fatal("slot bytes")
	}
	// The wrong key is a mismatch at the commitment, before any decryption.
	if bytes.Equal(slot[:32], derive(t, bodyKey, "veritra-c7-kc-v1", nil)) {
		t.Fatal("slot commitment equals another key's")
	}

	// Lengths: P(N) = 256 * ceil((512 + 128 N) / 256); body = P(N) + 124 + 700 N.
	for _, l := range out.Lengths {
		p := 256 * ((512 + 128*l.Channels + 255) / 256)
		if p != l.Body0Padded || p+124+700*l.Channels != l.HistorySyncBody {
			t.Fatalf("lengths for %d channels", l.Channels)
		}
	}
	if p := 256 * ((512 + 128*500 + 255) / 256); p != 64512 {
		t.Fatal("P(500)")
	}
}

// ---- ordering ---------------------------------------------------------------

type record struct {
	ID     string  `json:"id"`
	Seq    int     `json:"seq"`
	Prev   *string `json:"prev"`
	Mode   string  `json:"mode"`
	Reason string  `json:"reason"`
	Epoch  int     `json:"epoch"`
}

type expect struct {
	Row                  any     `json:"row"`
	Head                 *string `json:"head"`
	Status               string  `json:"status"`
	HighestSeq           int     `json:"highest_seq"`
	Mode                 string  `json:"mode"`
	SealsUnderHistoryKey bool    `json:"seals_under_history_key"`
	HandsOverKey         bool    `json:"hands_over_key"`
}

type step struct {
	Record   *record `json:"record"`
	Source   string  `json:"source"`
	KeyGiven bool    `json:"key_given"`
	Valid    *bool   `json:"valid"`
	Event    string  `json:"event"`
	Epoch    int     `json:"epoch"`
	ForEpoch int     `json:"for_epoch"`
	Expect   expect  `json:"expect"`
}

type genesisStep struct {
	Record   record `json:"record"`
	Source   string `json:"source"`
	KeyGiven bool   `json:"key_given"`
	Expect   expect `json:"expect"`
}

type chain struct {
	head    *record
	kept    map[int]*record
	highest int
	status  string
	missAt  int
}

func newChain() *chain { return &chain{kept: map[int]*record{}, highest: -1, status: "ok"} }

func prevOf(r *record) string {
	if r.Prev == nil {
		return ""
	}
	return *r.Prev
}

func (c *chain) mode() string {
	if c.head == nil {
		return "members_from_join"
	}
	return c.head.Mode
}

func (c *chain) seals() bool { return c.mode() == "full" && c.status == "ok" }

// apply is decision 4's table, written afresh from the design text. It
// returns 0 for a record whose chain shape is invalid.
func (c *chain) apply(x *record, source string, keyGiven bool) int {
	zeroPrev := x.Prev == nil
	if x.Reason == "create" && !(x.Seq == 0 && zeroPrev) || x.Reason != "create" && x.Seq == 0 {
		return 0
	}
	highest := c.highest
	if x.Seq > c.highest {
		defer func(s int) { c.highest = s }(x.Seq)
	}
	opens := x.Mode == "full"
	h := c.head
	set := func(r *record, status string, reset bool) {
		c.head = r
		if reset {
			c.kept = map[int]*record{}
		}
		c.kept[r.Seq] = r
		c.status = status
	}
	cleared := func(r *record) string {
		if r.Epoch > c.missAt {
			return "ok"
		}
		return "unsure"
	}
	if h == nil { // row 1
		st := "ok"
		if opens && !keyGiven {
			st = "keyless"
		}
		set(x, st, true)
		return 1
	}
	applied := c.kept[x.Seq]
	if applied == nil && h.Seq == x.Seq {
		applied = h
	}
	if applied != nil && applied.ID == x.ID { // row 2
		return 2
	}
	live := source == "proposal_live" && (x.Reason == "switch" || x.Reason == "move") && x.Seq > highest
	if x.Seq == h.Seq+1 && prevOf(x) == h.ID { // row 3
		if c.status == "closed" {
			if live { // the ordinary recovery chains from the head
				set(x, cleared(x), true)
			} else {
				set(x, "closed", false)
			}
			return 3
		}
		st := c.status
		switch {
		case opens && !keyGiven:
			st = "keyless"
		case st == "keyless" && !opens:
		case st == "unsure":
			st = cleared(x)
		default:
			st = "ok"
		}
		set(x, st, false)
		return 3
	}
	if source != "report" && x.Seq <= h.Seq && applied != nil && prevOf(applied) == prevOf(x) { // row 4
		return 4
	}
	if live { // row 5
		set(x, cleared(x), true)
		return 5
	}
	first := h.Seq
	for s := range c.kept {
		if s < first {
			first = s
		}
	}
	if x.Seq < first { // row 6
		return 6
	}
	c.status = "closed" // row 7
	return 7
}

func TestOrderingVector(t *testing.T) {
	var v struct {
		Ordering struct {
			Cases []struct {
				Name  string `json:"name"`
				Steps []step `json:"steps"`
			} `json:"cases"`
		} `json:"ordering"`
		Genesis struct {
			Expect  expect      `json:"expect"`
			Full    genesisStep `json:"then_full_create"`
			Keyless genesisStep `json:"then_keyless"`
		} `json:"implicit_genesis"`
	}
	load(t, "c7-ordering-v1.json", &v)
	rows := map[string]bool{}
	for _, c := range v.Ordering.Cases {
		ch := newChain()
		for i, s := range c.Steps {
			label := fmt.Sprintf("%s step %d", c.Name, i+1)
			switch {
			case s.Event == "unsure":
				if ch.mode() == "full" {
					ch.missAt = max(ch.missAt, s.Epoch)
					if ch.status == "ok" {
						ch.status = "unsure"
					}
				}
			case s.Event == "key_arrived":
				if ch.status == "keyless" {
					ch.status = "unsure"
					if s.ForEpoch > ch.missAt {
						ch.status = "ok"
					}
				}
			case s.Valid != nil && !*s.Valid:
				rows["invalid"] = true
				if s.Expect.Row != "invalid" {
					t.Fatalf("%s: an invalid record must expect \"invalid\"", label)
				}
			default:
				row := ch.apply(s.Record, s.Source, s.KeyGiven)
				var got any = float64(row)
				if row == 0 {
					got = "invalid"
					rows["invalid"] = true
				} else {
					rows[fmt.Sprint(row)] = true
				}
				if got != s.Expect.Row {
					t.Fatalf("%s: row %v, want %v", label, got, s.Expect.Row)
				}
			}
			head := ""
			if ch.head != nil {
				head = ch.head.ID
			}
			wantHead := ""
			if s.Expect.Head != nil {
				wantHead = *s.Expect.Head
			}
			if head != wantHead || ch.status != s.Expect.Status || ch.highest != s.Expect.HighestSeq {
				t.Fatalf("%s: head %q status %s highest %d; want %q %s %d", label, head, ch.status, ch.highest, wantHead, s.Expect.Status, s.Expect.HighestSeq)
			}
		}
	}
	for _, r := range []string{"1", "2", "3", "4", "5", "6", "7", "invalid"} {
		if !rows[r] {
			t.Fatalf("row %s not covered by the vector", r)
		}
	}

	g := newChain()
	if g.head != nil || g.mode() != v.Genesis.Expect.Mode || g.status != v.Genesis.Expect.Status ||
		g.seals() != v.Genesis.Expect.SealsUnderHistoryKey || g.highest != v.Genesis.Expect.HighestSeq {
		t.Fatal("implicit genesis")
	}
	for _, next := range []genesisStep{v.Genesis.Full, v.Genesis.Keyless} {
		c := newChain()
		if row := c.apply(&next.Record, next.Source, next.KeyGiven); float64(row) != next.Expect.Row ||
			c.status != next.Expect.Status || c.mode() != next.Expect.Mode || c.seals() != next.Expect.SealsUnderHistoryKey {
			t.Fatalf("genesis then %s: row %d status %s", next.Record.ID, row, c.status)
		}
	}
}

// ---- windows and slack ------------------------------------------------------

func TestWindowsVector(t *testing.T) {
	var v struct {
		Windows []struct {
			Name       string `json:"name"`
			Generation struct {
				Epoch      int    `json:"epoch"`
				Group      string `json:"group"`
				CloseEpoch *int   `json:"close_epoch"`
			} `json:"generation"`
			InPeriod bool `json:"in_current_period"`
			Body     struct {
				Gen        int    `json:"signed_gen"`
				Group      string `json:"signed_group"`
				Epoch      int    `json:"signed_epoch"`
				RouteEpoch int    `json:"route_epoch"`
			} `json:"body"`
			Accept bool `json:"accept"`
		} `json:"windows"`
	}
	load(t, "c7-ordering-v1.json", &v)
	if len(v.Windows) < 10 {
		t.Fatal("windows vector is too small")
	}
	for _, w := range v.Windows {
		g, b := w.Generation, w.Body
		ok := w.InPeriod && b.Gen == g.Epoch && b.Group == g.Group &&
			b.Epoch == b.RouteEpoch && g.Epoch <= b.Epoch && (g.CloseEpoch == nil || b.Epoch < *g.CloseEpoch)
		if ok != w.Accept {
			t.Fatalf("%s: accepted %v, want %v", w.Name, ok, w.Accept)
		}
	}
}

func TestRecordMessageSlackVector(t *testing.T) {
	var v struct {
		Slack struct {
			Conversation string `json:"conversation_id"`
			Sender       string `json:"sender_device_id"`
			Action       string `json:"action_id"`
			Channel      string `json:"channel_id"`
			Cases        []struct {
				Name         string `json:"name"`
				CompactBytes int    `json:"compact_bytes"`
				InnerJSON    int    `json:"inner_json_bytes"`
				Framed       int    `json:"framed_bytes"`
				VAP1         int    `json:"vap1_bytes"`
				Slack        int    `json:"slack"`
			} `json:"cases"`
		} `json:"vap1_slack"`
	}
	load(t, "c7-ordering-v1.json", &v)
	s := v.Slack
	for _, c := range s.Cases {
		// The key order is the order of AppPayloadCodec's inner JSON.
		inner := fmt.Sprintf(`{"v":2,"type":"history_change","conversation_id":%q,"sender_device_id":%q,"action_id":%q,"channel_id":%q,"hidden":true,"body":{"r":%q}}`,
			s.Conversation, s.Sender, s.Action, s.Channel, base64.StdEncoding.EncodeToString(make([]byte, c.CompactBytes)))
		framed := len(inner) + 8
		vap1 := (framed + 255) / 256 * 256
		if len(inner) != c.InnerJSON || framed != c.Framed || vap1 != c.VAP1 || vap1-framed != c.Slack {
			t.Fatalf("%s: inner %d framed %d vap1 %d slack %d", c.Name, len(inner), framed, vap1, vap1-framed)
		}
	}
}
