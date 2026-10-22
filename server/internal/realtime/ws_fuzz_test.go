package realtime

import (
	"bytes"
	"encoding/binary"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// These tests pin the documented parser bounds of drainClientFrames (see the
// "Inbound frame bounds" comment in websocket.go). The fuzz targets compare
// the parser against wsReferenceModel, an independent RFC 6455 reader with the
// same bounds, so they check accept/reject decisions and not only liveness.

// wsSentinel is a valid masked ping appended to every input. It is answered
// only if the parser accepted the whole preceding stream and is still between
// frames, which makes "rejected" and "accepted until EOF" observable.
var wsSentinel = maskedClientFrame(0x9, []byte("sentinel"))

// staticConn serves a fixed byte stream. Deadlines are no-ops, so the
// parser's only exit paths are a protocol decision or EOF.
type staticConn struct {
	net.Conn
	r *bytes.Reader
}

func (c *staticConn) Read(p []byte) (int, error)       { return c.r.Read(p) }
func (c *staticConn) SetReadDeadline(time.Time) error  { return nil }
func (c *staticConn) SetWriteDeadline(time.Time) error { return nil }
func (c *staticConn) SetDeadline(time.Time) error      { return nil }

// runParser feeds stream to drainClientFrames and returns the ping payloads it
// surfaced. The pong channel is large enough that it never fills, so the
// result is deterministic.
func runParser(t *testing.T, stream []byte) [][]byte {
	t.Helper()
	done := make(chan struct{})
	pongs := make(chan []byte, len(stream)/6+2)
	go drainClientFrames(&staticConn{r: bytes.NewReader(stream)}, done, pongs)
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("parser did not terminate on a finite stream")
	}
	close(pongs)
	var got [][]byte
	for payload := range pongs {
		if len(payload) > 125 {
			t.Fatalf("control payload of %d bytes surfaced", len(payload))
		}
		got = append(got, payload)
	}
	return got
}

// wsReferenceModel independently decodes a client stream under the documented
// bounds and returns the ping payloads a conforming reader answers before it
// stops (on close, protocol violation, bound violation or end of input).
func wsReferenceModel(stream []byte) [][]byte {
	var pings [][]byte
	pos := 0
	take := func(n int) ([]byte, bool) {
		if n < 0 || len(stream)-pos < n {
			return nil, false
		}
		out := stream[pos : pos+n]
		pos += n
		return out, true
	}
	inMessage := false
	var messageType byte
	messageLen := 0
	var message []byte
	for {
		head, ok := take(2)
		if !ok {
			return pings
		}
		fin := head[0]>>7 == 1
		rsv := (head[0] >> 4) & 0x7
		opcode := head[0] & 0xf
		control := opcode&0x8 != 0
		switch {
		case rsv != 0:
			return pings
		case opcode >= 3 && opcode <= 7, opcode >= 11:
			return pings
		case control && !fin:
			return pings
		case opcode == 0 && !inMessage:
			return pings
		case (opcode == 1 || opcode == 2) && inMessage:
			return pings
		case head[1]>>7 == 0: // unmasked client frame
			return pings
		}
		var length uint64
		switch n := head[1] & 0x7f; n {
		case 126:
			ext, ok := take(2)
			if !ok {
				return pings
			}
			length = uint64(binary.BigEndian.Uint16(ext))
			if length <= 125 {
				return pings // non-minimal encoding
			}
		case 127:
			ext, ok := take(8)
			if !ok {
				return pings
			}
			length = binary.BigEndian.Uint64(ext)
			if length>>63 == 1 || length <= 0xffff {
				return pings
			}
		default:
			length = uint64(n)
		}
		if length > maxFrameSize || control && length > 125 {
			return pings
		}
		mask, ok := take(4)
		if !ok {
			return pings
		}
		masked, ok := take(int(length))
		if !ok {
			return pings
		}
		payload := make([]byte, len(masked))
		for i := range masked {
			payload[i] = masked[i] ^ mask[i&3]
		}
		switch opcode {
		case 0x8:
			return pings // close ends the reader, valid or not
		case 0x9:
			pings = append(pings, payload)
			continue
		case 0xa:
			continue
		}
		if opcode != 0 {
			inMessage, messageType, messageLen, message = true, opcode, 0, message[:0]
		}
		messageLen += len(payload)
		if messageLen > maxFrameSize {
			return pings
		}
		if messageType == 1 {
			message = append(message, payload...)
		}
		if fin {
			if messageType == 1 && !utf8.Valid(message) {
				return pings
			}
			inMessage = false
		}
	}
}

func checkAgainstModel(t *testing.T, stream []byte) {
	t.Helper()
	want := wsReferenceModel(stream)
	got := runParser(t, stream)
	if len(got) != len(want) {
		t.Fatalf("parser answered %d pings, model %d", len(got), len(want))
	}
	for i := range got {
		if !bytes.Equal(got[i], want[i]) {
			t.Fatalf("ping %d payload differs: parser %x model %x", i, got[i], want[i])
		}
	}
}

func rawFrame(first, second byte, ext []byte, payload []byte) []byte {
	mask := [4]byte{0x11, 0x22, 0x33, 0x44}
	frame := append([]byte{first, second}, ext...)
	if second&0x80 != 0 {
		frame = append(frame, mask[:]...)
		for i, b := range payload {
			frame = append(frame, b^mask[i&3])
		}
		return frame
	}
	return append(frame, payload...)
}

func len16(n int) []byte { return binary.BigEndian.AppendUint16(nil, uint16(n)) }
func len64(n uint64) []byte {
	return binary.BigEndian.AppendUint64(nil, n)
}

func concatFrames(frames ...[]byte) []byte {
	return bytes.Join(frames, nil)
}

// TestDrainClientFramesBounds pins each documented bound at and just past its
// edge. "accepted" means the sentinel ping after the input is still answered.
func TestDrainClientFramesBounds(t *testing.T) {
	big := func(n int) []byte { return bytes.Repeat([]byte{'a'}, n) }
	tests := []struct {
		name     string
		input    []byte
		accepted bool
	}{
		{"empty text", maskedClientFrame(0x1, nil), true},
		{"binary at frame bound", maskedClientFrame(0x2, big(maxFrameSize)), true},
		{"binary past frame bound", maskedClientFrame(0x2, big(maxFrameSize+1)), false},
		{"16-bit length minimal", rawFrame(0x82, 0xfe, len16(126), big(126)), true},
		{"16-bit length non-minimal", rawFrame(0x82, 0xfe, len16(125), big(125)), false},
		{"64-bit length minimal", rawFrame(0x82, 0xff, len64(65536), big(65536)), true},
		{"64-bit length non-minimal", rawFrame(0x82, 0xff, len64(65535), big(65535)), false},
		{"64-bit length high bit", rawFrame(0x82, 0xff, len64(1<<63|200000), nil), false},
		{"64-bit length huge", rawFrame(0x82, 0xff, len64(1<<62), nil), false},
		{"ping at control bound", maskedClientFrame(0x9, big(125)), true},
		{"ping past control bound", rawFrame(0x89, 0xfe, len16(126), big(126)), false},
		{"pong ignored", maskedClientFrame(0xa, []byte("p")), true},
		{"unsolicited pong at control bound", maskedClientFrame(0xa, big(125)), true},
		{"fragmented message at bound", concatFrames(
			clientFrame(0x02, big(maxFrameSize/2)),
			clientFrame(0x80, big(maxFrameSize/2))), true},
		{"fragmented message past bound", concatFrames(
			clientFrame(0x02, big(maxFrameSize/2)),
			clientFrame(0x80, big(maxFrameSize/2+1))), false},
		{"many empty continuations", concatFrames(clientFrame(0x01, nil),
			bytes.Repeat(clientFrame(0x00, nil), 64), clientFrame(0x80, []byte("ok"))), true},
		{"ping inside fragmented message", concatFrames(
			clientFrame(0x01, []byte("he")), maskedClientFrame(0x9, []byte("x")),
			maskedClientFrame(0xa, nil), clientFrame(0x80, []byte("llo"))), true},
		{"utf8 split across fragments", concatFrames(
			clientFrame(0x01, []byte{0xe2, 0x82}), clientFrame(0x80, []byte{0xac})), true},
		{"truncated utf8 at message end", concatFrames(
			clientFrame(0x01, []byte{'o', 'k'}), clientFrame(0x80, []byte{0xe2, 0x82})), false},
		{"invalid utf8 in binary allowed", maskedClientFrame(0x2, []byte{0xff, 0xfe}), true},
		{"fragment left open", clientFrame(0x01, []byte("a")), true},
		{"close ends reader", maskedClientFrame(0x8, []byte{0x03, 0xe8}), false},
		{"empty close ends reader", maskedClientFrame(0x8, nil), false},
		{"rsv1", rawFrame(0xc1, 0x80, nil, nil), false},
		{"rsv2", rawFrame(0xa1, 0x80, nil, nil), false},
		{"rsv3", rawFrame(0x91, 0x80, nil, nil), false},
		{"unmasked data", rawFrame(0x81, 0x01, nil, []byte("a")), false},
		{"reserved data opcode", maskedClientFrame(0x7, nil), false},
		{"reserved control opcode", maskedClientFrame(0xb, nil), false},
		{"fragmented ping", clientFrame(0x09, nil), false},
		{"text during fragment", concatFrames(clientFrame(0x01, []byte("a")), clientFrame(0x81, nil)), false},
		{"orphan continuation", clientFrame(0x80, nil), false},
		{"truncated header", []byte{0x81}, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			stream := append(append([]byte{}, test.input...), wsSentinel...)
			if model := wsReferenceModel(stream); acceptedBy(model) != test.accepted {
				t.Fatalf("reference model accepted=%v, table says %v", acceptedBy(model), test.accepted)
			}
			got := runParser(t, stream)
			if acceptedBy(got) != test.accepted {
				t.Fatalf("parser accepted=%v, want %v", acceptedBy(got), test.accepted)
			}
			checkAgainstModel(t, stream)
		})
	}
}

func acceptedBy(pings [][]byte) bool {
	return len(pings) > 0 && bytes.Equal(pings[len(pings)-1], []byte("sentinel"))
}

func TestValidClosePayloadCodes(t *testing.T) {
	valid := map[uint16]bool{1000: true, 1001: true, 1002: true, 1003: true,
		1007: true, 1008: true, 1009: true, 1010: true, 1011: true, 1012: true,
		1013: true, 1014: true, 3000: true, 4999: true}
	for _, code := range []uint16{0, 999, 1000, 1001, 1002, 1003, 1004, 1005, 1006,
		1007, 1011, 1014, 1015, 1016, 2999, 3000, 4999, 5000, 65535} {
		payload := binary.BigEndian.AppendUint16(nil, code)
		if got := validClosePayload(payload); got != valid[code] {
			t.Errorf("close code %d valid=%v, want %v", code, got, valid[code])
		}
	}
	if !validClosePayload(nil) || validClosePayload([]byte{3}) ||
		!validClosePayload([]byte{0x03, 0xe8, 'o', 'k'}) || validClosePayload([]byte{0x03, 0xe8, 0xc0}) {
		t.Fatal("close payload length/reason rules changed")
	}
}

// TestDrainClientFramesPingBurstBound documents that a client which queues
// more pings than the pong buffer holds, faster than the writer drains them,
// is disconnected rather than buffered without limit.
func TestDrainClientFramesPingBurstBound(t *testing.T) {
	const buffer = 4
	stream := bytes.Repeat(maskedClientFrame(0x9, []byte("p")), buffer+1)
	stream = append(stream, wsSentinel...)
	done := make(chan struct{})
	pongs := make(chan []byte, buffer)
	go drainClientFrames(&staticConn{r: bytes.NewReader(stream)}, done, pongs)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("ping burst did not end the reader")
	}
	if len(pongs) != buffer {
		t.Fatalf("queued pongs=%d, want %d", len(pongs), buffer)
	}
}

// FuzzDrainClientFramesDifferential feeds raw bytes to the parser and checks
// its decisions against the reference model.
func FuzzDrainClientFramesDifferential(f *testing.F) {
	f.Add(maskedClientFrame(0x9, []byte("alive")))
	f.Add(concatFrames(clientFrame(0x01, []byte("he")), maskedClientFrame(0x9, nil), clientFrame(0x80, []byte("y"))))
	f.Add(rawFrame(0x82, 0xfe, len16(126), bytes.Repeat([]byte{1}, 126)))
	f.Add(rawFrame(0x82, 0xff, len64(65536), nil))
	f.Add(maskedClientFrame(0x8, []byte{0x03, 0xe8}))
	f.Add([]byte{0x81, 0x00})
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 1<<16 {
			t.Skip()
		}
		checkAgainstModel(t, append(append([]byte{}, data...), wsSentinel...))
	})
}

// FuzzDrainClientFramesStructured turns fuzz bytes into a sequence of mostly
// well-formed masked frames, so the fuzzer spends its time on fragmentation,
// control interleaving, length encodings and the frame/message bounds instead
// of failing at the first header byte.
func FuzzDrainClientFramesStructured(f *testing.F) {
	f.Add([]byte{0x01, 0x03, 'h', 'e', 'y', 0x89, 0x00, 0x80, 0x01, '!'})
	f.Add([]byte{0x02, 0xf7, 0x80, 0xf7})
	f.Add([]byte{0x01, 0x02, 0xe2, 0x82, 0x80, 0x01, 0xac})
	f.Add([]byte{0x88, 0x02, 0x03, 0xe8})
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 4096 {
			t.Skip()
		}
		stream := structuredFrames(data)
		checkAgainstModel(t, append(stream, wsSentinel...))
	})
}

// structuredFrames encodes each frame as: a header byte (FIN, RSV and opcode
// verbatim, so invalid combinations still occur), a length byte, then
// payload bytes. Length bytes 0xf0-0xff select boundary sizes (filled with
// 'a'). A header with all three RSV bits set is sent unmasked with RSV
// cleared, so most frames stay masked but the unmasked path is still reached.
func structuredFrames(data []byte) []byte {
	sizes := []int{126, 127, 65535, 65536, maxFrameSize/2 - 1, maxFrameSize / 2,
		maxFrameSize/2 + 1, maxFrameSize - 1, maxFrameSize, maxFrameSize + 1,
		0, 1, 124, 125, 3, 2}
	var out []byte
	budget := 4 * maxFrameSize
	for len(data) >= 2 && budget > 0 {
		first, n := data[0], data[1]
		data = data[2:]
		masked := true
		if first&0x70 == 0x70 {
			first &^= 0x70
			masked = false
		}
		var payload []byte
		if n >= 0xf0 {
			size := sizes[n-0xf0]
			budget -= size
			payload = bytes.Repeat([]byte{'a'}, size)
		} else {
			size := int(n)
			if size > len(data) {
				size = len(data)
			}
			payload, data = data[:size], data[size:]
		}
		frame := clientFrame(first, payload)
		if !masked {
			frame = rawFrame(first, frame[1]&0x7f, frame[2:len(frame)-4-len(payload)], payload)
		}
		out = append(out, frame...)
	}
	return out
}

// FuzzServerFrameWriters checks that frames the server emits are canonical
// RFC 6455 server frames: FIN set, unmasked, minimal length encoding, and
// exactly the payload.
func FuzzServerFrameWriters(f *testing.F) {
	f.Add([]byte("hello"), uint32(0))
	f.Add([]byte{}, uint32(125))
	f.Add([]byte{}, uint32(126))
	f.Add([]byte{}, uint32(65536))
	f.Fuzz(func(t *testing.T, seed []byte, pad uint32) {
		payload := append(append([]byte{}, seed...), bytes.Repeat([]byte{0x5a}, int(pad%(1<<17)))...)
		var text bytes.Buffer
		if err := writeTextFrame(&text, payload); err != nil {
			t.Fatal(err)
		}
		checkServerFrame(t, text.Bytes(), 0x1, payload)
		var pong bytes.Buffer
		err := writePongFrame(&pong, payload)
		if len(payload) > 125 {
			if err == nil {
				t.Fatal("oversized pong written")
			}
			return
		}
		if err != nil {
			t.Fatal(err)
		}
		checkServerFrame(t, pong.Bytes(), 0xa, payload)
	})
}

func checkServerFrame(t *testing.T, frame []byte, opcode byte, payload []byte) {
	t.Helper()
	if len(frame) < 2 || frame[0] != 0x80|opcode || frame[1]&0x80 != 0 {
		t.Fatalf("bad server frame header %x", frame[:min(len(frame), 2)])
	}
	n, offset := uint64(frame[1]&0x7f), 2
	switch n {
	case 126:
		n, offset = uint64(binary.BigEndian.Uint16(frame[2:4])), 4
		if n < 126 {
			t.Fatal("non-minimal 16-bit length")
		}
	case 127:
		n, offset = binary.BigEndian.Uint64(frame[2:10]), 10
		if n <= 0xffff || n>>63 != 0 {
			t.Fatal("non-minimal or invalid 64-bit length")
		}
	}
	if n != uint64(len(payload)) || !bytes.Equal(frame[offset:], payload) {
		t.Fatal("server frame payload mismatch")
	}
}

// FuzzWebSocketHandshakeHeaders checks the upgrade and origin predicates on
// arbitrary header values: an accepted origin is always same-host http(s)
// with no path, query, fragment or userinfo.
func FuzzWebSocketHandshakeHeaders(f *testing.F) {
	f.Add("websocket", "keep-alive, Upgrade", "13", "", "messenger.example.test")
	f.Add("WebSocket", "upgrade", " 13 ", "https://messenger.example.test", "messenger.example.test")
	f.Add("websocket", "Upgrade", "13", "https://evil.example", "messenger.example.test")
	f.Add("websocket", "Upgrade", "13", "https://u@messenger.example.test", "messenger.example.test")
	f.Fuzz(func(t *testing.T, upgrade, connection, version, origin, host string) {
		r := httptest.NewRequest(http.MethodGet, "http://placeholder/api/v1/sync/ws", nil)
		r.Host = host
		r.Header.Set("Upgrade", upgrade)
		r.Header.Set("Connection", connection)
		r.Header.Set("Sec-WebSocket-Version", version)
		r.Header.Set("Origin", origin)
		if isWebSocketUpgrade(r) {
			if strings.TrimSpace(r.Header.Get("Sec-WebSocket-Version")) != "13" ||
				!strings.EqualFold(strings.TrimSpace(r.Header.Get("Upgrade")), "websocket") {
				t.Fatal("upgrade accepted without websocket/13")
			}
		}
		if !originAllowed(r) {
			return
		}
		got := strings.TrimSpace(r.Header.Get("Origin"))
		if got == "" {
			return
		}
		u, err := url.Parse(got)
		if err != nil || !strings.EqualFold(u.Host, r.Host) || u.Host == "" || u.User != nil ||
			(u.Scheme != "http" && u.Scheme != "https") || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
			t.Fatalf("origin %q accepted for host %q", got, r.Host)
		}
	})
}
