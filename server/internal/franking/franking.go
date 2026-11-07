// Package franking implements the message-franking commitment of the C6
// design (docs/designs/C6-reports-franking.md). It is pure: no storage and no
// logging. The server never sees kf or the payload; this is the reference
// implementation and test vector source for the Rust and Dart sides.
package franking

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

const (
	// KeySize is the size of the per-message franking key kf.
	KeySize = 32
	// CommitSize is the size of the commitment c.
	CommitSize = sha256.Size

	// MaxIDSize is the largest context field, as in the Rust core
	// (MAX_FRANK_ID_BYTES in crypto/rust/src/report.rs).
	MaxIDSize = 128
	// MaxPayloadSize is the largest canonical payload (MAX_FRANK_PAYLOAD_BYTES).
	MaxPayloadSize = 64 * 1024

	label = "veritra-frank-v1"
)

// ErrKeySize reports a franking key of the wrong length.
var ErrKeySize = errors.New("franking: key must be 32 bytes")

// ErrInvalidInput reports a context field or payload outside the bounds the
// Rust core enforces: ids 1 to 128 bytes, payload 1 byte to 64 KiB.
var ErrInvalidInput = errors.New("franking: id or payload size out of bounds")

// Context is what the commitment binds besides the payload.
type Context struct {
	ConversationID string
	SenderDeviceID string
	ActionID       string
}

// Commit returns c = HMAC-SHA256(kf, label || ctx || payload) with each
// context field and the payload length-prefixed (uint32 big endian). payload
// is the canonical payload bytes with the "frank" member removed. The size
// bounds match the Rust core, so both sides refuse the same inputs.
func Commit(kf []byte, ctx Context, payload []byte) ([]byte, error) {
	if len(kf) != KeySize {
		return nil, ErrKeySize
	}
	for _, id := range []string{ctx.ConversationID, ctx.SenderDeviceID, ctx.ActionID} {
		if len(id) == 0 || len(id) > MaxIDSize {
			return nil, ErrInvalidInput
		}
	}
	if len(payload) == 0 || len(payload) > MaxPayloadSize {
		return nil, ErrInvalidInput
	}
	m := hmac.New(sha256.New, kf)
	m.Write([]byte(label))
	for _, f := range [][]byte{
		[]byte(ctx.ConversationID),
		[]byte(ctx.SenderDeviceID),
		[]byte(ctx.ActionID),
		payload,
	} {
		var n [4]byte
		binary.BigEndian.PutUint32(n[:], uint32(len(f)))
		m.Write(n[:])
		m.Write(f)
	}
	return m.Sum(nil), nil
}

// Verify reports whether commit matches the revealed key, context and
// payload, in constant time.
func Verify(commit, kf []byte, ctx Context, payload []byte) bool {
	want, err := Commit(kf, ctx, payload)
	if err != nil || len(commit) != CommitSize {
		return false
	}
	return hmac.Equal(commit, want)
}
