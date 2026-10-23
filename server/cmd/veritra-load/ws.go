package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// syncSocket is a minimal RFC 6455 client for the server-to-client sync
// socket: it reads text frames, answers pings and sends a close frame.
type syncSocket struct {
	conn    net.Conn
	reader  *bufio.Reader
	writeMu sync.Mutex
}

const maxSyncFrame = 4 << 20

func dialSync(ctx context.Context, base *url.URL, dev *device) (*syncSocket, error) {
	host := base.Host
	if base.Port() == "" {
		if base.Scheme == "https" {
			host = net.JoinHostPort(base.Hostname(), "443")
		} else {
			host = net.JoinHostPort(base.Hostname(), "80")
		}
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	var conn net.Conn
	var err error
	if base.Scheme == "https" {
		conn, err = (&tls.Dialer{NetDialer: dialer, Config: &tls.Config{ServerName: base.Hostname(), MinVersion: tls.VersionTLS12}}).DialContext(ctx, "tcp", host)
	} else {
		conn, err = dialer.DialContext(ctx, "tcp", host)
	}
	if err != nil {
		return nil, err
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		conn.Close()
		return nil, err
	}
	key := base64.StdEncoding.EncodeToString(nonce[:])
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base.String()+"/api/v1/sync/ws", nil)
	if err != nil {
		conn.Close()
		return nil, err
	}
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Sec-WebSocket-Key", key)
	req.Header.Set("Sec-WebSocket-Version", "13")
	req.Header.Set("Authorization", "Bearer "+dev.token)
	req.Header.Set("X-Forwarded-For", dev.ip)
	_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
	if err := req.Write(conn); err != nil {
		conn.Close()
		return nil, err
	}
	reader := bufio.NewReader(conn)
	resp, err := http.ReadResponse(reader, req)
	if err != nil {
		conn.Close()
		return nil, err
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		resp.Body.Close()
		conn.Close()
		return nil, statusError{resp.StatusCode}
	}
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	if resp.Header.Get("Sec-WebSocket-Accept") != base64.StdEncoding.EncodeToString(sum[:]) {
		conn.Close()
		return nil, errors.New("websocket handshake not accepted")
	}
	_ = conn.SetDeadline(time.Time{})
	return &syncSocket{conn: conn, reader: reader}, nil
}

// next returns the next text or binary message, answering control frames.
// The server pings every 54 s, so a read deadline of 90 s detects a dead peer.
func (s *syncSocket) next() ([]byte, error) {
	for {
		_ = s.conn.SetReadDeadline(time.Now().Add(90 * time.Second))
		opcode, payload, err := s.readFrame()
		if err != nil {
			return nil, err
		}
		switch opcode {
		case 0x1, 0x2:
			return payload, nil
		case 0x9:
			if err := s.writeFrame(0xA, payload); err != nil {
				return nil, err
			}
		case 0x8:
			_ = s.writeFrame(0x8, payload)
			return nil, io.EOF
		}
	}
}

func (s *syncSocket) readFrame() (byte, []byte, error) {
	var header [2]byte
	if _, err := io.ReadFull(s.reader, header[:]); err != nil {
		return 0, nil, err
	}
	if header[0]&0x80 == 0 {
		return 0, nil, errors.New("fragmented server frames are not expected")
	}
	opcode := header[0] & 0x0F
	length := uint64(header[1] & 0x7F)
	switch length {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(s.reader, ext[:]); err != nil {
			return 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(s.reader, ext[:]); err != nil {
			return 0, nil, err
		}
		length = binary.BigEndian.Uint64(ext[:])
	}
	if header[1]&0x80 != 0 || length > maxSyncFrame {
		return 0, nil, errors.New("unexpected server frame")
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(s.reader, payload); err != nil {
		return 0, nil, err
	}
	return opcode, payload, nil
}

// writeFrame sends one masked frame, as RFC 6455 requires of clients.
func (s *syncSocket) writeFrame(opcode byte, payload []byte) error {
	if len(payload) > 125 {
		return errors.New("control payload too long")
	}
	var mask [4]byte
	if _, err := rand.Read(mask[:]); err != nil {
		return err
	}
	frame := make([]byte, 0, 6+len(payload))
	frame = append(frame, 0x80|opcode, 0x80|byte(len(payload)))
	frame = append(frame, mask[:]...)
	for i, b := range payload {
		frame = append(frame, b^mask[i%4])
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	_, err := s.conn.Write(frame)
	return err
}

// close sends a normal close frame and closes the connection.
func (s *syncSocket) close() {
	_ = s.writeFrame(0x8, []byte{0x03, 0xE8})
	_ = s.conn.Close()
}

func isClosedError(err error) bool {
	return errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) || strings.Contains(err.Error(), "use of closed network connection")
}
