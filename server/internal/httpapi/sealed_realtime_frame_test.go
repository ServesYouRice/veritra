package httpapi_test

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A sealed post (L2-3) reaches a member's live WebSocket as the same bare
// frame every message event gets since C7: exactly
// {"version":"v1","type":"sync.available","created_at":…}. Before the
// integration the sealed handler sent the whole stored envelope (ciphertext,
// conversation id, event id) in the frame, to every member device whatever
// sync would serve it.
func TestSealedPostSendsOnlyTheBareSyncAvailableFrame(t *testing.T) {
	handler, ownerToken, _, _ := sealedHandler(t, nil)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedframe")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	sealedReaders(t, handler, ownerToken, memberToken)
	_, info := sealedInfo(t, handler, memberToken, conversationID)
	tokens, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 1)
	if status != http.StatusOK {
		t.Fatalf("tokens status=%d body=%s", status, body)
	}

	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	socket := dialTestWebSocket(t, server.URL, ownerToken)

	ciphertext := []byte("sealed-frame-ciphertext")
	status, response := postSealed(t, handler, sealedPostBody(conversationID, tokens[0], "sealed-frame-0000000000001", ciphertext, nil))
	if status != http.StatusCreated {
		t.Fatalf("sealed post status=%d body=%s", status, response)
	}
	var stored struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &stored); err != nil || stored.ID == "" {
		t.Fatalf("sealed post body=%s err=%v", response, err)
	}

	frames := socket.textFrames(t, 300*time.Millisecond)
	if len(frames) != 1 {
		t.Fatalf("got %d text frames, want exactly one: %q", len(frames), frames)
	}
	raw := frames[0]
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatalf("decode frame %s: %v", raw, err)
	}
	if len(fields) != 3 || string(fields["version"]) != `"v1"` || string(fields["type"]) != `"sync.available"` {
		t.Fatalf("frame is not the bare sync.available event: %s", raw)
	}
	var createdAt time.Time
	if err := json.Unmarshal(fields["created_at"], &createdAt); err != nil || createdAt.IsZero() {
		t.Fatalf("frame created_at %s: %v", fields["created_at"], err)
	}
	for _, leak := range []string{stored.ID, conversationID, base64.StdEncoding.EncodeToString(ciphertext), "message.sealed.created"} {
		if bytes.Contains(raw, []byte(leak)) {
			t.Fatalf("frame names the sealed message (%q): %s", leak, raw)
		}
	}

	// A replay stores and publishes nothing.
	if status, response := postSealed(t, handler, sealedPostBody(conversationID, tokens[0], "sealed-frame-0000000000001", ciphertext, nil)); status != http.StatusOK {
		t.Fatalf("sealed replay status=%d body=%s", status, response)
	}
	if again := socket.textFrames(t, 200*time.Millisecond); len(again) != 0 {
		t.Fatalf("a replay published %q", again)
	}
}

type testWebSocket struct {
	conn   net.Conn
	reader *bufio.Reader
}

// dialTestWebSocket opens /api/v1/sync/ws on a real socket with token.
func dialTestWebSocket(t *testing.T, serverURL, token string) *testWebSocket {
	t.Helper()
	conn, err := net.Dial("tcp", strings.TrimPrefix(serverURL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	request := "GET /api/v1/sync/ws HTTP/1.1\r\n" +
		"Host: " + strings.TrimPrefix(serverURL, "http://") + "\r\n" +
		"Authorization: Bearer " + token + "\r\n" +
		"Connection: Upgrade\r\nUpgrade: websocket\r\n" +
		"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
	if _, err := io.WriteString(conn, request); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, nil)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("upgrade status=%d", response.StatusCode)
	}
	return &testWebSocket{conn: conn, reader: reader}
}

// textFrames reads the server's frames for wait and returns the payloads of
// the text frames. Server frames are unmasked and, here, unfragmented.
func (s *testWebSocket) textFrames(t *testing.T, wait time.Duration) [][]byte {
	t.Helper()
	var frames [][]byte
	if err := s.conn.SetReadDeadline(time.Now().Add(wait)); err != nil {
		t.Fatal(err)
	}
	for {
		var header [2]byte
		if _, err := io.ReadFull(s.reader, header[:]); err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				return frames
			}
			t.Fatalf("read frame header: %v", err)
		}
		if header[1]&0x80 != 0 {
			t.Fatalf("server frame is masked")
		}
		length := uint64(header[1] & 0x7f)
		switch length {
		case 126:
			var ext [2]byte
			if _, err := io.ReadFull(s.reader, ext[:]); err != nil {
				t.Fatal(err)
			}
			length = uint64(binary.BigEndian.Uint16(ext[:]))
		case 127:
			var ext [8]byte
			if _, err := io.ReadFull(s.reader, ext[:]); err != nil {
				t.Fatal(err)
			}
			length = binary.BigEndian.Uint64(ext[:])
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(s.reader, payload); err != nil {
			t.Fatalf("read frame payload: %v", err)
		}
		if header[0]&0x0f == 0x1 {
			frames = append(frames, payload)
		}
	}
}
