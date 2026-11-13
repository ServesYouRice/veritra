package c7vector

import (
	"bytes"
	"encoding/binary"
	"errors"
	"testing"
)

// moveVector is testing/vectors/c7-move-v1.json, made by
// testing/vectors/c7-move-v1.py: the 128-byte wrap of a C7 move and the
// compact move record that carries it. Rust and Dart check it too.
type moveVector struct {
	Valid []struct {
		Name           string `json:"name"`
		PrevEpoch      uint64 `json:"prev_epoch"`
		PrevKey        string `json:"prev_key_hex"`
		PrevGroup      string `json:"prev_group_id"`
		PrevCloseEpoch uint64 `json:"prev_close_epoch"`
		Wrap           string `json:"wrap_hex"`
	} `json:"valid_wraps"`
	Invalid []struct {
		Name string `json:"name"`
		Wrap string `json:"wrap_hex"`
	} `json:"invalid_wraps"`
	Record struct {
		Seq        uint32 `json:"seq"`
		Prev       string `json:"prev_hex"`
		Mode       uint8  `json:"mode"`
		Reason     uint8  `json:"reason"`
		CloseEpoch uint64 `json:"close_epoch"`
		Key        string `json:"key_hex"`
		Sig        string `json:"sig_hex"`
		CloseGroup string `json:"close_group_id"`
		Wrap       string `json:"wrap_hex"`
		Compact    string `json:"compact_hex"`
		Length     int    `json:"compact_length"`
	} `json:"record"`
	Mismatched []struct {
		Name string `json:"name"`
		Wrap string `json:"wrap_hex"`
	} `json:"mismatched_wraps"`
}

type moveWrap struct {
	prevEpoch      uint64
	prevKey        []byte
	prevGroup      []byte
	prevCloseEpoch uint64
}

// decodeMoveWrap is the wrap's structure, written from the design text
// alone: u64 E_prev | CHK_prev[32] | lp(prev_group_id) | u64 E_prev_close,
// zero-padded to 128 bytes; a 1-64 byte id, a non-zero key, and
// E_prev <= E_prev_close.
func decodeMoveWrap(b []byte) (moveWrap, error) {
	bad := errors.New("invalid move wrap")
	if len(b) != 128 {
		return moveWrap{}, bad
	}
	w := moveWrap{prevEpoch: binary.BigEndian.Uint64(b[:8]), prevKey: b[8:40]}
	n := int(binary.BigEndian.Uint16(b[40:42]))
	if n == 0 || n > 64 {
		return moveWrap{}, bad
	}
	w.prevGroup = b[42 : 42+n]
	w.prevCloseEpoch = binary.BigEndian.Uint64(b[42+n : 50+n])
	if bytes.Count(b[50+n:], []byte{0}) != len(b[50+n:]) ||
		bytes.Equal(w.prevKey, make([]byte, 32)) || w.prevEpoch > w.prevCloseEpoch {
		return moveWrap{}, bad
	}
	return w, nil
}

func TestMoveWrapVector(t *testing.T) {
	var v moveVector
	load(t, "c7-move-v1.json", &v)
	if len(v.Valid) == 0 || len(v.Invalid) == 0 || len(v.Mismatched) == 0 {
		t.Fatal("vector has no cases")
	}
	for _, c := range v.Valid {
		w, err := decodeMoveWrap(unhex(t, c.Wrap))
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		if w.prevEpoch != c.PrevEpoch || !bytes.Equal(w.prevKey, unhex(t, c.PrevKey)) ||
			string(w.prevGroup) != c.PrevGroup || w.prevCloseEpoch != c.PrevCloseEpoch {
			t.Fatalf("%s: fields differ", c.Name)
		}
	}
	for _, c := range v.Invalid {
		if _, err := decodeMoveWrap(unhex(t, c.Wrap)); err == nil {
			t.Fatalf("%s: accepted", c.Name)
		}
	}
	// The compact move record, rebuilt from its fields.
	r := v.Record
	var compact []byte
	compact = append(compact, 1)
	compact = binary.BigEndian.AppendUint32(compact, r.Seq)
	compact = append(compact, unhex(t, r.Prev)...)
	compact = append(compact, r.Mode, r.Reason)
	compact = binary.BigEndian.AppendUint64(compact, r.CloseEpoch)
	compact = append(compact, unhex(t, r.Key)...)
	compact = append(compact, unhex(t, r.Sig)...)
	compact = binary.BigEndian.AppendUint16(compact, uint16(len(r.CloseGroup)))
	compact = append(compact, r.CloseGroup...)
	compact = append(compact, unhex(t, r.Wrap)...)
	if r.Reason != 2 || len(compact) != r.Length || len(compact) != 143+2+len(r.CloseGroup)+128 ||
		!bytes.Equal(compact, unhex(t, r.Compact)) {
		t.Fatal("compact move record")
	}
	fits := func(w moveWrap) bool {
		return string(w.prevGroup) == r.CloseGroup && w.prevCloseEpoch == r.CloseEpoch
	}
	if w, err := decodeMoveWrap(unhex(t, r.Wrap)); err != nil || !fits(w) {
		t.Fatal("the record's own wrap does not fit it")
	}
	for _, c := range v.Mismatched {
		w, err := decodeMoveWrap(unhex(t, c.Wrap))
		if err != nil || fits(w) {
			t.Fatalf("%s: err=%v, fits", c.Name, err)
		}
	}
}
