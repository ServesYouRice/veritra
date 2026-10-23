package realtime

import (
	"bytes"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestValidCloseCodes(t *testing.T) {
	valid := map[uint16]bool{1000: true, 1001: true, 1002: true, 1003: true,
		1007: true, 1008: true, 1009: true, 1010: true, 1011: true, 1012: true,
		1013: true, 1014: true, 3000: true, 4999: true}
	for _, code := range []uint16{0, 999, 1000, 1001, 1002, 1003, 1004, 1005, 1006,
		1007, 1011, 1014, 1015, 1016, 2999, 3000, 4999, 5000, 65535} {
		if got := validCloseCode(code); got != valid[code] {
			t.Errorf("close code %d valid=%v, want %v", code, got, valid[code])
		}
	}
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
