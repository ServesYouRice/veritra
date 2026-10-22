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
	"unicode/utf8"
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

// readResult is what a frameReader produced for a fixed input stream.
type readResult struct {
	reply    closeReply
	pongs    [][]byte
	messages []inboundMessage
}

// readFrames runs a frameReader over an in-memory client byte stream.
func readFrames(input []byte) readResult {
	messages := make(chan inboundMessage)
	stop := make(chan struct{})
	reader := &frameReader{
		r:           bufio.NewReader(bytes.NewReader(input)),
		setDeadline: func(time.Time) error { return nil },
		pongs:       make(chan []byte, maxQueuedPongs),
		messages:    messages,
		stop:        stop,
	}
	var result readResult
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		result.reply = reader.run()
	}()
	collecting := true
	for collecting {
		select {
		case message := <-messages:
			result.messages = append(result.messages, message)
		case <-finished:
			collecting = false
		}
	}
	close(stop)
	close(reader.pongs)
	for payload := range reader.pongs {
		result.pongs = append(result.pongs, payload)
	}
	return result
}

func concatFrames(frames ...[]byte) []byte {
	return bytes.Join(frames, nil)
}

func TestFrameReaderAnswersMaskedPingAndRejectsUnmasked(t *testing.T) {
	result := readFrames(maskedClientFrame(opPing, []byte("alive")))
	if len(result.pongs) != 1 || string(result.pongs[0]) != "alive" {
		t.Fatalf("pongs=%q", result.pongs)
	}
	if result.reply.send {
		t.Fatalf("EOF must not send a close frame: %+v", result.reply)
	}
	result = readFrames([]byte{0x89, 0x00})
	if result.reply != (closeReply{send: true, code: closeProtocolError}) || len(result.pongs) != 0 {
		t.Fatalf("unmasked frame result=%+v", result)
	}
}

func TestFrameReaderRejectsMalformedSequences(t *testing.T) {
	big := bytes.Repeat([]byte{'a'}, maxClientMessageSize/2+1)
	tests := []struct {
		name   string
		frames [][]byte
		code   uint16
	}{
		{name: "reserved bit", frames: [][]byte{clientFrame(0xc1, []byte("x"))}, code: closeProtocolError},
		{name: "reserved data opcode", frames: [][]byte{clientFrame(0x83, nil)}, code: closeProtocolError},
		{name: "reserved control opcode", frames: [][]byte{clientFrame(0x8b, nil)}, code: closeProtocolError},
		{name: "fragmented control", frames: [][]byte{clientFrame(0x09, nil)}, code: closeProtocolError},
		{name: "continuation without start", frames: [][]byte{clientFrame(0x80, nil)}, code: closeProtocolError},
		{name: "new data during fragment", frames: [][]byte{clientFrame(0x01, []byte("a")), clientFrame(0x82, nil)}, code: closeProtocolError},
		{name: "invalid text", frames: [][]byte{clientFrame(0x81, []byte{0xff})}, code: closeInvalidPayload},
		{name: "invalid fragmented text", frames: [][]byte{clientFrame(0x01, []byte{0xc3}), clientFrame(0x80, []byte{0x28})}, code: closeInvalidPayload},
		{name: "truncated fragmented text then EOF", frames: [][]byte{clientFrame(0x01, []byte{0xe2, 0x82})}, code: 0},
		{name: "truncated final text", frames: [][]byte{clientFrame(0x01, []byte{0xe2, 0x82}), clientFrame(0x80, nil)}, code: closeInvalidPayload},
		{name: "invalid text fails fast", frames: [][]byte{clientFrame(0x01, []byte{0xce, 0xba, 0xf5})}, code: closeInvalidPayload},
		{name: "one byte close", frames: [][]byte{clientFrame(0x88, []byte{1})}, code: closeProtocolError},
		{name: "invalid close code", frames: [][]byte{clientFrame(0x88, []byte{0x03, 0xed})}, code: closeProtocolError},
		{name: "reserved close code 1015", frames: [][]byte{clientFrame(0x88, []byte{0x03, 0xf7})}, code: closeProtocolError},
		{name: "invalid close reason", frames: [][]byte{clientFrame(0x88, []byte{0x03, 0xe8, 0xff})}, code: closeInvalidPayload},
		{name: "oversized close", frames: [][]byte{clientFrame(0x88, append([]byte{0x03, 0xe8}, bytes.Repeat([]byte{'a'}, 124)...))}, code: closeProtocolError},
		{name: "noncanonical short length", frames: [][]byte{{0x81, 0xfe, 0, 1, 1, 2, 3, 4, 'y'}}, code: closeProtocolError},
		{name: "noncanonical long length", frames: [][]byte{{0x82, 0xff, 0, 0, 0, 0, 0, 0, 0xff, 0xff}}, code: closeProtocolError},
		{name: "length high bit", frames: [][]byte{{0x82, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0}}, code: closeProtocolError},
		{name: "oversized control", frames: [][]byte{{0x89, 0xfe, 0, 126}}, code: closeProtocolError},
		{name: "oversized frame", frames: [][]byte{{0x82, 0xff, 0, 0, 0, 0, 0, 0x10, 0, 1}}, code: closeMessageTooBig},
		{name: "frame one over bound", frames: [][]byte{clientFrame(0x82, make([]byte, maxClientMessageSize+1))}, code: closeMessageTooBig},
		{name: "oversized fragmented message", frames: [][]byte{clientFrame(0x02, big), clientFrame(0x80, big)}, code: closeMessageTooBig},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result := readFrames(concatFrames(test.frames...))
			want := closeReply{send: test.code != 0, code: test.code}
			if result.reply != want || len(result.messages) != 0 {
				t.Fatalf("reply=%+v messages=%d want=%+v", result.reply, len(result.messages), want)
			}
		})
	}
}

func TestFrameReaderAcceptsBoundsFragmentationAndControlInterleaving(t *testing.T) {
	limit := bytes.Repeat([]byte{'b'}, maxClientMessageSize)
	half := limit[:maxClientMessageSize/2]
	result := readFrames(concatFrames(
		clientFrame(0x01, []byte("hel")),
		clientFrame(0x89, []byte("alive")),
		clientFrame(0x00, []byte{0xe2, 0x82}), // split U+20AC across fragments
		clientFrame(0x8a, []byte("unsolicited")),
		clientFrame(0x80, []byte{0xac, 'o'}),
		clientFrame(0x82, limit),
		clientFrame(0x02, half),
		clientFrame(0x80, half),
		clientFrame(0x89, bytes.Repeat([]byte{'p'}, maxControlPayload)),
		clientFrame(0x88, []byte{0x0f, 0xa0, 'b', 'y', 'e'}),
	))
	if result.reply != (closeReply{send: true, code: 4000}) {
		t.Fatalf("reply=%+v", result.reply)
	}
	if len(result.messages) != 3 ||
		result.messages[0].opcode != opText || string(result.messages[0].payload) != "hel€o" ||
		result.messages[1].opcode != opBinary || len(result.messages[1].payload) != maxClientMessageSize ||
		result.messages[2].opcode != opBinary || len(result.messages[2].payload) != maxClientMessageSize {
		t.Fatalf("messages=%d", len(result.messages))
	}
	if len(result.pongs) != 2 || string(result.pongs[0]) != "alive" || len(result.pongs[1]) != maxControlPayload {
		t.Fatalf("pongs=%d", len(result.pongs))
	}
	if empty := readFrames(clientFrame(0x88, nil)); empty.reply != (closeReply{send: true}) {
		t.Fatalf("empty close reply=%+v", empty.reply)
	}
}

func TestFrameReaderBoundsPingFlood(t *testing.T) {
	var frames [][]byte
	for i := 0; i < 1000; i++ {
		frames = append(frames, clientFrame(0x89, []byte{byte(i), byte(i >> 8)}))
	}
	result := readFrames(concatFrames(frames...))
	if len(result.pongs) != maxQueuedPongs {
		t.Fatalf("queued pongs=%d", len(result.pongs))
	}
	last := result.pongs[len(result.pongs)-1]
	if last[0] != byte(999&0xff) || last[1] != byte(999>>8) {
		t.Fatal("most recent ping was not kept")
	}
}

func TestServeWebSocketReadsBytesBufferedDuringHandshake(t *testing.T) {
	writer, peer := newHijackResponseWriter()
	defer peer.Close()
	// Simulate the server's bufio.Reader having consumed a client frame that
	// arrived in the same packet as the upgrade request.
	buffered := io.MultiReader(bytes.NewReader(clientFrame(0x88, []byte{0x03, 0xe8})), writer.conn)
	writer.rw = bufio.NewReadWriter(bufio.NewReader(buffered), bufio.NewWriter(writer.conn))
	received := make(chan []byte, 1)
	go func() {
		reader := bufio.NewReader(peer)
		for {
			line, err := reader.ReadString('\n')
			if err != nil || line == "\r\n" {
				break
			}
		}
		head := make([]byte, 4)
		_, _ = io.ReadFull(reader, head)
		received <- head
		_, _ = io.Copy(io.Discard, reader)
	}()
	client := &Client{send: make(chan []byte, 1)}
	if err := ServeWebSocket(writer, validUpgradeRequest(context.Background()), client, time.Now().Add(time.Hour), func() {}); err != nil {
		t.Fatal(err)
	}
	select {
	case head := <-received:
		if !bytes.Equal(head, []byte{0x88, 0x02, 0x03, 0xe8}) {
			t.Fatalf("close echo=%x", head)
		}
	case <-time.After(time.Second):
		t.Fatal("buffered close frame was not processed")
	}
}

func TestCheckUTF8PrefixMatchesStdlib(t *testing.T) {
	inputs := [][]byte{
		[]byte("plain"), []byte("κόσμε"), {0xf0, 0x90, 0x80, 0x80}, {0xf4, 0x8f, 0xbf, 0xbf},
		{0xf4, 0x90, 0x80, 0x80}, {0xed, 0xa0, 0x80}, {0xe0, 0x80, 0xaf}, {0xc0, 0xaf}, {0xff}, {0xe0, 0xa0},
		{0xce, 0xba, 0xe1, 0xbd, 0xb9, 0xcf, 0x83, 0xce, 0xbc, 0xce, 0xb5, 0xed, 0xa0, 0x80, 0x65, 0x64, 0x69, 0x74, 0x65, 0x64},
	}
	for _, input := range inputs {
		assertUTF8Split(t, input)
	}
}

// assertUTF8Split checks that incremental validation split at every point
// agrees with utf8.Valid on the whole input, and that a rejected prefix can
// never be completed into valid UTF-8 (fail-fast is sound).
func assertUTF8Split(t testing.TB, input []byte) {
	t.Helper()
	want := utf8.Valid(input)
	for split := 0; split <= len(input); split++ {
		offset, ok := checkUTF8Prefix(input[:split], 0)
		if !ok && want {
			t.Fatalf("input=%x split=%d: valid input rejected early", input, split)
		}
		if ok {
			offset, ok = checkUTF8Prefix(input, offset)
		}
		if got := ok && offset == len(input); got != want {
			t.Fatalf("input=%x split=%d got=%v want=%v", input, split, got, want)
		}
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
