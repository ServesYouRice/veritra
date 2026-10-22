package realtime

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// echoHandler serves the production upgrade and frame parser over real TCP,
// echoing inbound data messages so a protocol client can observe the parser.
// It exists only in tests (RFC 6455 conformance and the Autobahn harness).
func echoHandler(w http.ResponseWriter, r *http.Request) {
	conn, rw, err := upgradeWebSocket(w, r)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = serveConn(r.Context(), conn, rw, nil, time.Now().Add(time.Hour), true)
}

// TestAutobahnEchoServer runs the echo harness for an external Autobahn
// fuzzingclient. It is skipped unless VERITRA_AUTOBAHN_LISTEN is set, e.g.
//
//	VERITRA_AUTOBAHN_LISTEN=127.0.0.1:9001 go test -run TestAutobahnEchoServer -timeout 0 ./internal/realtime
func TestAutobahnEchoServer(t *testing.T) {
	addr := os.Getenv("VERITRA_AUTOBAHN_LISTEN")
	if addr == "" {
		t.Skip("VERITRA_AUTOBAHN_LISTEN not set")
	}
	duration := 10 * time.Minute
	if value := os.Getenv("VERITRA_AUTOBAHN_DURATION"); value != "" {
		parsed, err := time.ParseDuration(value)
		if err != nil {
			t.Fatal(err)
		}
		duration = parsed
	}
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(echoHandler), ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = server.Serve(listener) }()
	time.Sleep(duration)
	_ = server.Close()
}

type wireFrame struct {
	opcode  byte
	payload []byte
}

func closeBody(code uint16) []byte {
	if code == 0 {
		return nil
	}
	body := make([]byte, 2)
	binary.BigEndian.PutUint16(body, code)
	return body
}

// TestRFC6455Conformance mirrors the Autobahn|Testsuite sections that apply to
// a server without extensions, over a real TCP connection: each case sends
// client frames and expects an exact sequence of server frames, ending with a
// close frame followed by the server closing TCP.
func TestRFC6455Conformance(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(echoHandler))
	defer server.Close()

	text := func(s string) []byte { return clientFrame(0x81, []byte(s)) }
	closeFrame := func(code uint16, reason ...byte) []byte {
		return clientFrame(0x88, append(closeBody(code), reason...))
	}
	echoClose := func(code uint16) wireFrame { return wireFrame{opcode: opClose, payload: closeBody(code)} }
	sized := func(n int) []byte { return bytes.Repeat([]byte{'*'}, n) }

	type testCase struct {
		section string
		name    string
		send    [][]byte
		want    []wireFrame
	}
	cases := []testCase{}
	add := func(section, name string, send [][]byte, want ...wireFrame) {
		cases = append(cases, testCase{section: section, name: name, send: send, want: want})
	}

	// 1. Framing: text and binary echo at every length-encoding boundary.
	for _, n := range []int{0, 125, 126, 127, 128, 65535, 65536} {
		add("1.1", fmt.Sprintf("text %d", n), [][]byte{clientFrame(0x81, sized(n)), closeFrame(1000)},
			wireFrame{opText, sized(n)}, echoClose(1000))
		add("1.2", fmt.Sprintf("binary %d", n), [][]byte{clientFrame(0x82, sized(n)), closeFrame(1000)},
			wireFrame{opBinary, sized(n)}, echoClose(1000))
	}
	// 2. Pings and pongs.
	add("2.1", "empty ping", [][]byte{clientFrame(0x89, nil), closeFrame(1000)}, wireFrame{opPong, nil}, echoClose(1000))
	add("2.2", "ping text payload", [][]byte{clientFrame(0x89, []byte("Hello, world!")), closeFrame(1000)},
		wireFrame{opPong, []byte("Hello, world!")}, echoClose(1000))
	add("2.3", "ping binary payload", [][]byte{clientFrame(0x89, []byte{0, 0xff, 0xfe, 0xfd}), closeFrame(1000)},
		wireFrame{opPong, []byte{0, 0xff, 0xfe, 0xfd}}, echoClose(1000))
	add("2.4", "ping 125", [][]byte{clientFrame(0x89, sized(125)), closeFrame(1000)}, wireFrame{opPong, sized(125)}, echoClose(1000))
	add("2.5", "ping 126 rejected", [][]byte{clientFrame(0x89, sized(126))}, echoClose(1002))
	add("2.7", "unsolicited pong ignored", [][]byte{clientFrame(0x8a, nil), closeFrame(1000)}, echoClose(1000))
	add("2.8", "unsolicited pong with payload", [][]byte{clientFrame(0x8a, []byte("unsolicited")), closeFrame(1000)}, echoClose(1000))
	add("2.9", "pong then ping", [][]byte{clientFrame(0x8a, []byte("x")), clientFrame(0x89, []byte("y")), closeFrame(1000)},
		wireFrame{opPong, []byte("y")}, echoClose(1000))
	tenPings, tenPongs := [][]byte{}, []wireFrame{}
	for i := 0; i < 10; i++ {
		tenPings = append(tenPings, clientFrame(0x89, []byte{byte('0' + i)}))
		tenPongs = append(tenPongs, wireFrame{opPong, []byte{byte('0' + i)}})
	}
	add("2.10", "ten pings", append(tenPings, closeFrame(1000)), append(tenPongs, echoClose(1000))...)
	// 3. Reserved bits.
	for rsv := byte(1); rsv <= 7; rsv++ {
		add("3", fmt.Sprintf("rsv %d on text", rsv), [][]byte{text("ok"), clientFrame(0x81|rsv<<4, []byte("x"))},
			wireFrame{opText, []byte("ok")}, echoClose(1002))
	}
	add("3", "rsv on ping", [][]byte{clientFrame(0xb9, nil)}, echoClose(1002))
	add("3", "rsv on close", [][]byte{clientFrame(0x98, closeBody(1000))}, echoClose(1002))
	// 4. Reserved opcodes.
	for _, opcode := range []byte{3, 4, 5, 6, 7, 0xb, 0xc, 0xd, 0xe, 0xf} {
		add("4", fmt.Sprintf("opcode %#x", opcode), [][]byte{text("ok"), clientFrame(0x80|opcode, []byte("x"))},
			wireFrame{opText, []byte("ok")}, echoClose(1002))
	}
	// 5. Fragmentation.
	add("5.1", "fragmented ping", [][]byte{clientFrame(0x09, []byte("a")), clientFrame(0x80, []byte("b"))}, echoClose(1002))
	add("5.2", "fragmented pong", [][]byte{clientFrame(0x0a, []byte("a"))}, echoClose(1002))
	add("5.3", "text in two fragments", [][]byte{clientFrame(0x01, []byte("frag")), clientFrame(0x80, []byte("ment")), closeFrame(1000)},
		wireFrame{opText, []byte("fragment")}, echoClose(1000))
	add("5.6", "ping between fragments", [][]byte{clientFrame(0x01, []byte("frag")), clientFrame(0x89, []byte("p")), clientFrame(0x80, []byte("ment")), closeFrame(1000)},
		wireFrame{opPong, []byte("p")}, wireFrame{opText, []byte("fragment")}, echoClose(1000))
	add("5.9", "continuation without start", [][]byte{clientFrame(0x80, []byte("x")), text("never")}, echoClose(1002))
	add("5.15", "text after final then continuation", [][]byte{text("a"), clientFrame(0x80, []byte("b"))},
		wireFrame{opText, []byte("a")}, echoClose(1002))
	add("5.18", "new text frame while fragmented", [][]byte{clientFrame(0x01, []byte("a")), clientFrame(0x01, []byte("b"))}, echoClose(1002))
	add("5.19", "empty fragments", [][]byte{clientFrame(0x01, nil), clientFrame(0x00, nil), clientFrame(0x80, nil), closeFrame(1000)},
		wireFrame{opText, nil}, echoClose(1000))
	// 6. UTF-8 handling.
	kosme := []byte("κόσμε")
	add("6.2", "valid multibyte text", [][]byte{clientFrame(0x81, kosme), closeFrame(1000)}, wireFrame{opText, kosme}, echoClose(1000))
	var perByte [][]byte
	for i, b := range kosme {
		first := byte(0x00)
		if i == 0 {
			first = 0x01
		}
		if i == len(kosme)-1 {
			first |= 0x80
		}
		perByte = append(perByte, clientFrame(first, []byte{b}))
	}
	add("6.2", "valid text one byte per fragment", append(perByte, closeFrame(1000)), wireFrame{opText, kosme}, echoClose(1000))
	add("6.3", "invalid text", [][]byte{clientFrame(0x81, append(append([]byte(nil), kosme...), 0xed, 0xa0, 0x80, 'e', 'd'))}, echoClose(1007))
	add("6.4", "invalid text in first fragment fails fast", [][]byte{clientFrame(0x01, []byte{0xce, 0xba, 0xf4, 0x90})}, echoClose(1007))
	add("6.6", "truncated sequence at end", [][]byte{clientFrame(0x81, []byte{0xce})}, echoClose(1007))
	add("6.8", "codepoint above U+10FFFF", [][]byte{clientFrame(0x81, []byte{0xf4, 0x90, 0x80, 0x80})}, echoClose(1007))
	add("6.12", "lone continuation byte", [][]byte{clientFrame(0x81, []byte{0x80})}, echoClose(1007))
	add("6.18", "overlong slash", [][]byte{clientFrame(0x81, []byte{0xc0, 0xaf})}, echoClose(1007))
	add("6.19", "UTF-16 surrogate", [][]byte{clientFrame(0x81, []byte{0xed, 0xa0, 0x80})}, echoClose(1007))
	add("6.22", "U+10FFFF and noncharacters valid", [][]byte{clientFrame(0x81, []byte{0xf4, 0x8f, 0xbf, 0xbf, 0xef, 0xbf, 0xbe}), closeFrame(1000)},
		wireFrame{opText, []byte{0xf4, 0x8f, 0xbf, 0xbf, 0xef, 0xbf, 0xbe}}, echoClose(1000))
	add("6.23", "U+FFFD valid", [][]byte{clientFrame(0x81, []byte{0xef, 0xbf, 0xbd}), closeFrame(1000)},
		wireFrame{opText, []byte{0xef, 0xbf, 0xbd}}, echoClose(1000))
	// 7. Close handling.
	add("7.1", "empty close", [][]byte{closeFrame(0)}, echoClose(0))
	add("7.1", "frames after close ignored", [][]byte{closeFrame(1000), text("late"), clientFrame(0x89, nil)}, echoClose(1000))
	add("7.3", "one byte close", [][]byte{clientFrame(0x88, []byte{0x03})}, echoClose(1002))
	add("7.3", "close with reason", [][]byte{closeFrame(1000, []byte("Hello World!")...)}, echoClose(1000))
	add("7.3", "close 125 bytes", [][]byte{closeFrame(1000, sized(123)...)}, echoClose(1000))
	add("7.3", "close 126 bytes", [][]byte{closeFrame(1000, sized(124)...)}, echoClose(1002))
	add("7.5", "close reason invalid UTF-8", [][]byte{closeFrame(1000, 0xce, 0xba, 0xed, 0xa0, 0x80)}, echoClose(1007))
	for _, code := range []uint16{1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014, 3000, 3999, 4000, 4999} {
		add("7.7", fmt.Sprintf("valid close code %d", code), [][]byte{closeFrame(code)}, echoClose(code))
	}
	for _, code := range []uint16{0, 999, 1004, 1005, 1006, 1015, 1016, 1100, 2000, 2999, 5000, 65535} {
		add("7.9", fmt.Sprintf("invalid close code %d", code), [][]byte{clientFrame(0x88, []byte{byte(code >> 8), byte(code)})}, echoClose(1002))
	}
	// 9 (bounded). Message-size limits for this push-only socket.
	add("9", "binary at limit", [][]byte{clientFrame(0x82, sized(maxClientMessageSize)), closeFrame(1000)},
		wireFrame{opBinary, sized(maxClientMessageSize)}, echoClose(1000))
	add("9", "binary over limit", [][]byte{clientFrame(0x82, sized(maxClientMessageSize+1))}, echoClose(1009))
	add("9", "fragmented over limit", [][]byte{clientFrame(0x02, sized(maxClientMessageSize)), clientFrame(0x80, sized(1))}, echoClose(1009))
	// Masking.
	add("5.1(RFC)", "unmasked client frame", [][]byte{{0x81, 0x02, 'h', 'i'}}, echoClose(1002))

	for _, tc := range cases {
		t.Run(tc.section+" "+tc.name, func(t *testing.T) {
			conn, reader := dialEcho(t, server.URL)
			defer conn.Close()
			go func() {
				for _, frame := range tc.send {
					if _, err := conn.Write(frame); err != nil {
						return
					}
				}
			}()
			for i, want := range tc.want {
				got, err := readServerFrame(reader)
				if err != nil {
					t.Fatalf("frame %d: %v", i, err)
				}
				if got.opcode != want.opcode || !bytes.Equal(got.payload, want.payload) {
					t.Fatalf("frame %d: opcode=%#x len=%d want opcode=%#x len=%d", i, got.opcode, len(got.payload), want.opcode, len(want.payload))
				}
			}
			// After its close frame the server closes the TCP connection.
			if extra, err := readServerFrame(reader); !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) && !isConnReset(err) {
				t.Fatalf("expected TCP close after close frame, got frame opcode=%#x err=%v", extra.opcode, err)
			}
		})
	}
	t.Logf("RFC 6455 conformance: %d cases", len(cases))
}

func isConnReset(err error) bool {
	return err != nil && strings.Contains(err.Error(), "connection reset")
}

func dialEcho(t *testing.T, serverURL string) (net.Conn, *bufio.Reader) {
	t.Helper()
	conn, err := net.Dial("tcp", strings.TrimPrefix(serverURL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	request := "GET /ws HTTP/1.1\r\nHost: test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + "\r\n\r\n"
	if _, err := io.WriteString(conn, request); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, nil)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusSwitchingProtocols || response.Header.Get("Sec-WebSocket-Accept") != websocketAccept(key) {
		t.Fatalf("handshake status=%d", response.StatusCode)
	}
	return conn, reader
}

// readServerFrame reads one server frame and checks server-side invariants:
// FIN set, no RSV bits, never masked.
func readServerFrame(reader *bufio.Reader) (wireFrame, error) {
	var head [2]byte
	if _, err := io.ReadFull(reader, head[:]); err != nil {
		return wireFrame{}, err
	}
	if head[0]&0x80 == 0 || head[0]&0x70 != 0 || head[1]&0x80 != 0 {
		return wireFrame{}, fmt.Errorf("invalid server frame header %x", head)
	}
	length := uint64(head[1] & 0x7f)
	switch length {
	case 126:
		var buf [2]byte
		if _, err := io.ReadFull(reader, buf[:]); err != nil {
			return wireFrame{}, err
		}
		length = uint64(binary.BigEndian.Uint16(buf[:]))
	case 127:
		var buf [8]byte
		if _, err := io.ReadFull(reader, buf[:]); err != nil {
			return wireFrame{}, err
		}
		length = binary.BigEndian.Uint64(buf[:])
	}
	if length > 1<<20 {
		return wireFrame{}, fmt.Errorf("server frame too large: %d", length)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(reader, payload); err != nil {
		return wireFrame{}, err
	}
	if len(payload) == 0 {
		payload = nil
	}
	return wireFrame{opcode: head[0] & 0x0f, payload: payload}, nil
}
