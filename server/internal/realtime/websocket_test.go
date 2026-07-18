package realtime

import (
	"bytes"
	"encoding/binary"
	"net"
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

func maskedClientFrame(opcode byte, payload []byte) []byte {
	mask := [4]byte{1, 2, 3, 4}
	frame := []byte{0x80 | opcode, 0x80 | byte(len(payload))}
	frame = append(frame, mask[:]...)
	for i, value := range payload {
		frame = append(frame, value^mask[i%len(mask)])
	}
	return frame
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
