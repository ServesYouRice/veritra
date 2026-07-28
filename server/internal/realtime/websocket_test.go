package realtime

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestWebSocketHandshakeAndServerFrames(t *testing.T) {
	if got := websocketAccept("dGhlIHNhbXBsZSBub25jZQ=="); got != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" {
		t.Fatalf("accept=%q", got)
	}
	for _, size := range []int{0, 125, 126, 65535, 65536} {
		payload := bytes.Repeat([]byte{0x42}, size)
		var frame bytes.Buffer
		if err := writeTextFrame(&frame, payload); err != nil {
			t.Fatalf("size %d: %v", size, err)
		}
		decoded, opcode := decodeServerFrame(t, frame.Bytes())
		if opcode != 1 || !bytes.Equal(decoded, payload) {
			t.Fatalf("size %d frame mismatch", size)
		}
	}
	var pong bytes.Buffer
	if err := writePongFrame(&pong, bytes.Repeat([]byte{1}, 126)); err == nil {
		t.Fatal("oversized control frame accepted")
	}
}

func TestDrainClientFramesAnswersMaskedPingAndRejectsUnmasked(t *testing.T) {
	server, client := net.Pipe()
	done := make(chan struct{})
	pongs := make(chan []byte, 1)
	go drainClientFrames(server, done, pongs)

	payload := []byte("alive")
	if _, err := client.Write(maskedClientFrame(0x9, payload)); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-pongs:
		if !bytes.Equal(got, payload) {
			t.Fatalf("pong payload=%q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("masked ping was not surfaced")
	}
	_ = client.Close()
	<-done

	server, client = net.Pipe()
	done = make(chan struct{})
	go drainClientFrames(server, done, make(chan []byte, 1))
	if _, err := client.Write([]byte{0x89, 0x00}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("unmasked client frame was not rejected")
	}
	_ = client.Close()
}

func TestDrainClientFramesRejectsMalformedSequences(t *testing.T) {
	tests := []struct {
		name   string
		frames [][]byte
	}{
		{name: "reserved bit", frames: [][]byte{clientFrame(0xc1, []byte("x"))}},
		{name: "reserved opcode", frames: [][]byte{clientFrame(0x83, nil)}},
		{name: "fragmented control", frames: [][]byte{clientFrame(0x09, nil)}},
		{name: "continuation without start", frames: [][]byte{clientFrame(0x80, nil)}},
		{name: "new data during fragment", frames: [][]byte{clientFrame(0x01, []byte("a")), clientFrame(0x82, nil)}},
		{name: "invalid text", frames: [][]byte{clientFrame(0x81, []byte{0xff})}},
		{name: "invalid fragmented text", frames: [][]byte{clientFrame(0x01, []byte{0xc3}), clientFrame(0x80, []byte{0x28})}},
		{name: "one byte close", frames: [][]byte{clientFrame(0x88, []byte{1})}},
		{name: "invalid close code", frames: [][]byte{clientFrame(0x88, []byte{0x03, 0xed})}},
		{name: "invalid close reason", frames: [][]byte{clientFrame(0x88, []byte{0x03, 0xe8, 0xff})}},
		{name: "noncanonical short length", frames: [][]byte{{0x81, 0xfe, 0, 1, 1, 2, 3, 4, 'y'}}},
		{name: "oversized control", frames: [][]byte{{0x89, 0xfe, 0, 126}}},
		{name: "oversized frame", frames: [][]byte{{0x82, 0xff, 0, 0, 0, 0, 0, 0x10, 0, 1}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server, client := net.Pipe()
			done := make(chan struct{})
			go drainClientFrames(server, done, make(chan []byte, 1))
			go func() {
				defer client.Close()
				for _, frame := range test.frames {
					if _, err := client.Write(frame); err != nil {
						return
					}
				}
			}()
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("malformed frame sequence was not closed")
			}
		})
	}
}

func TestDrainClientFramesAcceptsFragmentationAndControlInterleaving(t *testing.T) {
	server, client := net.Pipe()
	done := make(chan struct{})
	pongs := make(chan []byte, 1)
	go drainClientFrames(server, done, pongs)
	go func() {
		defer client.Close()
		frames := [][]byte{
			clientFrame(0x01, []byte("hel")),
			clientFrame(0x89, []byte("alive")),
			clientFrame(0x80, []byte("lo")),
			clientFrame(0x88, []byte{0x03, 0xe8}),
		}
		for _, frame := range frames {
			if _, err := client.Write(frame); err != nil {
				return
			}
		}
	}()
	select {
	case payload := <-pongs:
		if string(payload) != "alive" {
			t.Fatalf("pong payload=%q", payload)
		}
	case <-time.After(time.Second):
		t.Fatal("interleaved ping was not handled")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("valid close did not finish the reader")
	}
}

func TestServeWebSocketRejectsOriginAndHandlesLifecycle(t *testing.T) {
	for _, origin := range []string{"https://attacker.example", "https://messenger.example.test/path", "javascript://messenger.example.test"} {
		badOrigin := validUpgradeRequest(context.Background())
		badOrigin.Header.Set("Origin", origin)
		recorder := httptest.NewRecorder()
		client := &Client{send: make(chan []byte, 1)}
		if err := ServeWebSocket(recorder, badOrigin, client, time.Now().Add(time.Hour), func() {}); err == nil || recorder.Code != http.StatusForbidden {
			t.Fatalf("origin %q status=%d err=%v", origin, recorder.Code, err)
		}
	}

	tests := []struct {
		name    string
		context func(context.Context) (context.Context, context.CancelFunc)
		expires time.Duration
		stop    func(*Client, context.CancelFunc)
		wantErr bool
	}{
		{
			name: "session expiry", context: context.WithCancel, expires: 20 * time.Millisecond,
			stop: func(*Client, context.CancelFunc) {},
		},
		{
			name: "request cancellation", context: context.WithCancel, expires: time.Hour,
			stop: func(_ *Client, cancel context.CancelFunc) { cancel() }, wantErr: true,
		},
		{
			name: "hub shutdown", context: context.WithCancel, expires: time.Hour,
			stop: func(client *Client, _ context.CancelFunc) { client.Close() },
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := test.context(context.Background())
			defer cancel()
			request := validUpgradeRequest(ctx)
			writer, peer := newHijackResponseWriter()
			defer peer.Close()
			go io.Copy(io.Discard, peer)
			client := &Client{send: make(chan []byte, 1)}
			unregistered := make(chan struct{}, 1)
			go func() {
				time.Sleep(20 * time.Millisecond)
				test.stop(client, cancel)
			}()
			err := ServeWebSocket(writer, request, client, time.Now().Add(test.expires), func() { unregistered <- struct{}{} })
			if (err != nil) != test.wantErr {
				t.Fatalf("ServeWebSocket error=%v", err)
			}
			select {
			case <-unregistered:
			default:
				t.Fatal("client was not unregistered")
			}
		})
	}
}

func TestHubConcurrentPublishAndDisconnect(t *testing.T) {
	hub := NewHub()
	const clients = 8
	registered := make([]*Client, 0, clients)
	for i := 0; i < clients; i++ {
		client, err := hub.Register("account", string(rune('a'+i)), "127.0.0.1")
		if err != nil {
			t.Fatal(err)
		}
		registered = append(registered, client)
	}
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			hub.Publish([]string{"account"}, Event{Type: "test", ID: int64(id)})
		}(i)
	}
	for _, client := range registered {
		wg.Add(1)
		go func(client *Client) {
			defer wg.Done()
			hub.Unregister(client)
		}(client)
	}
	wg.Wait()
	if got := hub.ConnectionCount(); got != 0 {
		t.Fatalf("connections=%d", got)
	}
}

func TestHubBoundsSlowClientsAndDrains(t *testing.T) {
	hub := NewHub()
	client, err := hub.Register("account", "device", "203.0.113.10")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 1000; i++ {
		hub.Publish([]string{"account"}, Event{Type: "test", ID: int64(i)})
	}
	if buffered := len(client.send); buffered != cap(client.send) {
		t.Fatalf("slow client buffered=%d capacity=%d", buffered, cap(client.send))
	}
	hub.Drain()
	if hub.ConnectionCount() != 0 {
		t.Fatal("drain retained connections")
	}
	if _, err := hub.Register("other", "device", "203.0.113.11"); !errors.Is(err, ErrHubDraining) {
		t.Fatalf("registration after drain error=%v", err)
	}
}

func FuzzDrainClientFrames(f *testing.F) {
	f.Add(maskedClientFrame(0x9, []byte("alive")))
	f.Add(clientFrame(0x88, []byte{0x03, 0xe8}))
	f.Add([]byte{0x81, 0x00})
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > maxFrameSize+32 {
			t.Skip()
		}
		server, client := net.Pipe()
		done := make(chan struct{})
		go drainClientFrames(server, done, make(chan []byte, 4))
		go func() {
			_, _ = client.Write(data)
			_ = client.Close()
		}()
		select {
		case <-done:
		case <-time.After(time.Second):
			_ = client.Close()
			t.Fatal("parser did not terminate after peer close")
		}
	})
}

func maskedClientFrame(opcode byte, payload []byte) []byte {
	return clientFrame(0x80|opcode, payload)
}

func clientFrame(first byte, payload []byte) []byte {
	mask := [4]byte{1, 2, 3, 4}
	frame := []byte{first}
	switch {
	case len(payload) <= 125:
		frame = append(frame, 0x80|byte(len(payload)))
	case len(payload) <= 65535:
		frame = append(frame, 0xfe, 0, 0)
		binary.BigEndian.PutUint16(frame[2:], uint16(len(payload)))
	default:
		frame = append(frame, 0xff, 0, 0, 0, 0, 0, 0, 0, 0)
		binary.BigEndian.PutUint64(frame[2:], uint64(len(payload)))
	}
	frame = append(frame, mask[:]...)
	for i, value := range payload {
		frame = append(frame, value^mask[i%len(mask)])
	}
	return frame
}

func validUpgradeRequest(ctx context.Context) *http.Request {
	request := httptest.NewRequest(http.MethodGet, "https://messenger.example.test/api/v1/sync/ws", nil).WithContext(ctx)
	request.Header.Set("Connection", "keep-alive, Upgrade")
	request.Header.Set("Upgrade", "websocket")
	request.Header.Set("Sec-WebSocket-Version", "13")
	request.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	return request
}

type hijackResponseWriter struct {
	header http.Header
	conn   net.Conn
	rw     *bufio.ReadWriter
}

func newHijackResponseWriter() (*hijackResponseWriter, net.Conn) {
	server, client := net.Pipe()
	return &hijackResponseWriter{
		header: make(http.Header),
		conn:   server,
		rw:     bufio.NewReadWriter(bufio.NewReader(server), bufio.NewWriter(server)),
	}, client
}

func (w *hijackResponseWriter) Header() http.Header               { return w.header }
func (w *hijackResponseWriter) Write(payload []byte) (int, error) { return len(payload), nil }
func (w *hijackResponseWriter) WriteHeader(int)                   {}
func (w *hijackResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return w.conn, w.rw, nil
}

func decodeServerFrame(t *testing.T, frame []byte) ([]byte, byte) {
	t.Helper()
	if len(frame) < 2 || frame[0]&0x80 == 0 || frame[1]&0x80 != 0 {
		t.Fatal("invalid server frame header")
	}
	opcode := frame[0] & 0xf
	offset := 2
	length := int(frame[1] & 0x7f)
	if length == 126 {
		length = int(binary.BigEndian.Uint16(frame[offset : offset+2]))
		offset += 2
	} else if length == 127 {
		length = int(binary.BigEndian.Uint64(frame[offset : offset+8]))
		offset += 8
	}
	if offset+length != len(frame) {
		t.Fatal("invalid server frame length")
	}
	return frame[offset:], opcode
}
