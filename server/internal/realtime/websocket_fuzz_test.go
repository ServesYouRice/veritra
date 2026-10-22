package realtime

import (
	"bytes"
	"encoding/binary"
	"testing"
	"unicode/utf8"
)

// Fuzz targets for the inbound frame parser. Run one at a time, e.g.
//
//	go test -fuzz=FuzzFrameReader -fuzztime=30s ./internal/realtime
//
// Crashers found by the fuzzer are committed under testdata/fuzz/<Target>/
// and replay as regression seeds on every plain `go test`.

// FuzzFrameReader feeds raw, possibly malformed client bytes to the parser
// and checks its output invariants.
func FuzzFrameReader(f *testing.F) {
	f.Add(maskedClientFrame(opPing, []byte("alive")))
	f.Add(clientFrame(0x88, []byte{0x03, 0xe8}))
	f.Add([]byte{0x81, 0x00})
	f.Add(concatFrames(clientFrame(0x01, []byte("hel")), clientFrame(0x89, nil), clientFrame(0x80, []byte("lo"))))
	f.Add([]byte{0x82, 0xff, 0, 0, 0, 0, 0, 0x10, 0, 1})
	f.Add([]byte{0x81, 0xfe, 0x00, 0x7e, 1, 2, 3, 4})
	f.Add(clientFrame(0x81, []byte{0xce, 0xba, 0xed, 0xa0, 0x80}))
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 4*maxClientMessageSize {
			t.Skip()
		}
		result := readFrames(data)
		if result.reply.send && result.reply.code != 0 && !validCloseCode(result.reply.code) {
			t.Fatalf("server would send invalid close code %d", result.reply.code)
		}
		if !result.reply.send && result.reply.code != 0 {
			t.Fatalf("close code without close frame: %+v", result.reply)
		}
		if len(result.pongs) > maxQueuedPongs {
			t.Fatalf("pong queue exceeded bound: %d", len(result.pongs))
		}
		for _, pong := range result.pongs {
			if len(pong) > maxControlPayload {
				t.Fatalf("pong payload %d bytes", len(pong))
			}
		}
		for _, message := range result.messages {
			if len(message.payload) > maxClientMessageSize {
				t.Fatalf("message of %d bytes exceeded bound", len(message.payload))
			}
			if message.opcode != opText && message.opcode != opBinary {
				t.Fatalf("delivered opcode %#x", message.opcode)
			}
			if message.opcode == opText && !utf8.Valid(message.payload) {
				t.Fatal("delivered invalid UTF-8 text")
			}
		}
	})
}

// FuzzFragmentation decodes the fuzz input into a sequence of correctly
// masked and length-encoded frames with arbitrary header bits, opcodes, FIN
// flags and payloads, then compares the parser against an independent
// reference model of RFC 6455 §5.4/§5.5/§8.1 behaviour.
//
// Input encoding, repeated: one header byte (FIN|RSV|opcode), one length byte,
// then the payload. Length bytes 0xfc-0xff instead generate a large payload
// of max/2, max/2+1, max or max+1 bytes to exercise the size bounds.
func FuzzFragmentation(f *testing.F) {
	f.Add([]byte{0x01, 3, 'h', 'e', 'l', 0x89, 0, 0x80, 2, 'l', 'o'})
	f.Add([]byte{0x01, 2, 0xe2, 0x82, 0x80, 1, 0xac})
	f.Add([]byte{0x02, 0xfc, 0x80, 0xfd})
	f.Add([]byte{0x82, 0xfe, 0x82, 0xff})
	f.Add([]byte{0x01, 1, 'a', 0x82, 0})
	f.Add([]byte{0x80, 0})
	f.Add([]byte{0x09, 0})
	f.Add([]byte{0x88, 2, 0x03, 0xe8})
	f.Add([]byte{0x01, 3, 0xce, 0xba, 0xf5})
	f.Add([]byte{0x81, 1, 'x', 0xc1, 1, 'y'})
	f.Fuzz(func(t *testing.T, data []byte) {
		frames := decodeFuzzFrames(data)
		var stream []byte
		for _, frame := range frames {
			stream = append(stream, clientFrame(frame.first, frame.payload)...)
		}
		got := readFrames(stream)
		want := referenceRead(frames)
		if got.reply != want.reply {
			t.Fatalf("reply=%+v want=%+v", got.reply, want.reply)
		}
		if len(got.messages) != len(want.messages) {
			t.Fatalf("messages=%d want=%d", len(got.messages), len(want.messages))
		}
		for i := range got.messages {
			if got.messages[i].opcode != want.messages[i].opcode || !bytes.Equal(got.messages[i].payload, want.messages[i].payload) {
				t.Fatalf("message %d differs", i)
			}
		}
		if len(got.pongs) != len(want.pongs) {
			t.Fatalf("pongs=%d want=%d", len(got.pongs), len(want.pongs))
		}
		for i := range got.pongs {
			if !bytes.Equal(got.pongs[i], want.pongs[i]) {
				t.Fatalf("pong %d differs", i)
			}
		}
	})
}

// FuzzControlFrame sends one control-range frame (opcode 0x8-0xf, any FIN
// and payload length) followed by a normal close.
func FuzzControlFrame(f *testing.F) {
	f.Add(byte(0x9), true, []byte("alive"))
	f.Add(byte(0x9), false, []byte{})
	f.Add(byte(0xa), true, []byte("pong"))
	f.Add(byte(0x8), true, []byte{0x03, 0xe8, 'o', 'k'})
	f.Add(byte(0x8), true, []byte{0x03, 0xec})
	f.Add(byte(0x8), true, []byte{0x0b, 0xb8, 0xff})
	f.Add(byte(0xb), true, []byte{})
	f.Add(byte(0x9), true, bytes.Repeat([]byte{'p'}, 126))
	f.Fuzz(func(t *testing.T, opcode byte, fin bool, payload []byte) {
		if len(payload) > 1024 {
			t.Skip()
		}
		opcode = 0x8 | opcode&0x7
		first := opcode
		if fin {
			first |= 0x80
		}
		frames := []fuzzFrame{{first: first, payload: payload}, {first: 0x88, payload: []byte{0x03, 0xe8}}}
		var stream []byte
		for _, frame := range frames {
			stream = append(stream, clientFrame(frame.first, frame.payload)...)
		}
		got := readFrames(stream)
		want := referenceRead(frames)
		if got.reply != want.reply || len(got.messages) != 0 {
			t.Fatalf("reply=%+v want=%+v", got.reply, want.reply)
		}
		if opcode == opPing && fin && len(payload) <= maxControlPayload {
			if len(got.pongs) != 1 || !bytes.Equal(got.pongs[0], payload) {
				t.Fatal("valid ping not answered with identical pong payload")
			}
		} else if len(got.pongs) != 0 {
			t.Fatal("pong queued for a non-ping or rejected frame")
		}
	})
}

// FuzzUTF8Prefix checks incremental fragment UTF-8 validation against the
// standard library at every split point.
func FuzzUTF8Prefix(f *testing.F) {
	f.Add([]byte("κόσμε"))
	f.Add([]byte{0xed, 0xa0, 0x80})
	f.Add([]byte{0xf4, 0x90, 0x80, 0x80})
	f.Add([]byte{0xe0, 0x80, 0xaf})
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 256 {
			t.Skip()
		}
		assertUTF8Split(t, data)
	})
}

type fuzzFrame struct {
	first   byte
	payload []byte
}

func decodeFuzzFrames(data []byte) []fuzzFrame {
	var frames []fuzzFrame
	for len(data) >= 2 && len(frames) < 32 {
		first, length := data[0], int(data[1])
		data = data[2:]
		var payload []byte
		if length >= 0xfc {
			payload = bytes.Repeat([]byte{'a'}, []int{maxClientMessageSize / 2, maxClientMessageSize/2 + 1, maxClientMessageSize, maxClientMessageSize + 1}[length-0xfc])
		} else {
			if length > len(data) {
				length = len(data)
			}
			payload = append([]byte(nil), data[:length]...)
			data = data[length:]
		}
		frames = append(frames, fuzzFrame{first: first, payload: payload})
	}
	return frames
}

// referenceRead is a deliberately naive model of the parser: whole-buffer
// UTF-8 checks, brute-force completion of partial code points, and an
// explicit close-code list.
func referenceRead(frames []fuzzFrame) readResult {
	var result readResult
	fail := func(code uint16) readResult {
		result.reply = closeReply{send: true, code: code}
		return result
	}
	var openOpcode byte
	var buffer []byte
	for _, frame := range frames {
		fin := frame.first&0x80 != 0
		rsv := frame.first & 0x70
		opcode := frame.first & 0x0f
		known := map[byte]bool{0: true, 1: true, 2: true, 8: true, 9: true, 10: true}
		if rsv != 0 || !known[opcode] {
			return fail(1002)
		}
		control := opcode >= 8
		if control && !fin || opcode == 0 && openOpcode == 0 || (opcode == 1 || opcode == 2) && openOpcode != 0 {
			return fail(1002)
		}
		if control && len(frame.payload) > 125 {
			return fail(1002)
		}
		if len(frame.payload) > 64<<10 || opcode == 0 && len(buffer)+len(frame.payload) > 64<<10 {
			return fail(1009)
		}
		switch opcode {
		case 8:
			return fail(referenceCloseReply(frame.payload))
		case 9:
			result.pongs = append(result.pongs, frame.payload)
			if len(result.pongs) > 16 {
				result.pongs = result.pongs[1:]
			}
		case 10:
		case 1, 2:
			if fin {
				if opcode == 1 && !utf8.Valid(frame.payload) {
					return fail(1007)
				}
				result.messages = append(result.messages, inboundMessage{opcode: opcode, payload: frame.payload})
				continue
			}
			openOpcode, buffer = opcode, append([]byte(nil), frame.payload...)
		case 0:
			buffer = append(buffer, frame.payload...)
		}
		if openOpcode == 1 && (opcode == 0 || opcode == 1) {
			if fin && !utf8.Valid(buffer) || !fin && !referenceCompletable(buffer) {
				return fail(1007)
			}
		}
		if opcode == 0 && fin {
			result.messages = append(result.messages, inboundMessage{opcode: openOpcode, payload: buffer})
			openOpcode, buffer = 0, nil
		}
	}
	return result
}

func referenceCloseReply(payload []byte) uint16 {
	switch {
	case len(payload) == 0:
		// Echo an empty close body.
		return 0
	case len(payload) == 1:
		return 1002
	}
	code := binary.BigEndian.Uint16(payload)
	valid := map[uint16]bool{1000: true, 1001: true, 1002: true, 1003: true, 1007: true, 1008: true,
		1009: true, 1010: true, 1011: true, 1012: true, 1013: true, 1014: true}
	if !utf8.Valid(payload[2:]) {
		return 1007
	}
	if !valid[code] && (code < 3000 || code > 4999) {
		return 1002
	}
	return code
}

// referenceCompletable reports whether some suffix of up to three bytes makes
// b valid UTF-8. 0x80/0x90/0xa0 cover every lead-specific second-byte range.
func referenceCompletable(b []byte) bool {
	if utf8.Valid(b) {
		return true
	}
	candidates := []byte{0x80, 0x90, 0xa0}
	for _, c1 := range candidates {
		for k := 1; k <= 3; k++ {
			suffix := append([]byte{c1}, bytes.Repeat([]byte{0x80}, k-1)...)
			if utf8.Valid(append(append([]byte(nil), b...), suffix...)) {
				return true
			}
		}
	}
	return false
}
