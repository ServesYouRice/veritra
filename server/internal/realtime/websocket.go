package realtime

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	maxFrameSize  = 1 << 20 // 1 MiB per inbound client frame

	// Keepalive parameters. We ping the client every pingPeriod and require any
	// frame (a pong or other data) within pongWait, so a half-open TCP peer is
	// reaped instead of pinning a goroutine and subscription indefinitely.
	writeWait  = 10 * time.Second
	pongWait   = 60 * time.Second
	pingPeriod = (pongWait * 9) / 10
)

func ServeWebSocket(w http.ResponseWriter, r *http.Request, client *Client, sessionExpiresAt time.Time, unregister func()) error {
	defer unregister()
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		http.Error(w, "websocket upgrade required", http.StatusUpgradeRequired)
		return errors.New("websocket upgrade required")
	}
	if !originAllowed(r) {
		http.Error(w, "origin not allowed", http.StatusForbidden)
		return errors.New("origin not allowed")
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	if key == "" {
		http.Error(w, "missing websocket key", http.StatusBadRequest)
		return errors.New("missing websocket key")
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijacking unsupported", http.StatusInternalServerError)
		return errors.New("hijacking unsupported")
	}
	conn, rw, err := hijacker.Hijack()
	if err != nil {
		return err
	}
	defer conn.Close()
	// After hijack the http.Server no longer manages this connection. Set an
	// explicit write deadline for the handshake (and refresh it before every
	// subsequent write) rather than leaving the server's timeouts in place
	// (which would kill the long-lived socket) or clearing them entirely
	// (which would let a dead peer pin this goroutine forever).
	_ = conn.SetWriteDeadline(time.Now().Add(writeWait))

	accept := websocketAccept(key)
	if _, err := fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept); err != nil {
		return err
	}
	if err := rw.Flush(); err != nil {
		return err
	}

	done := make(chan struct{})
	pongs := make(chan []byte, 4)
	go drainClientFrames(conn, done, pongs)
	ticker := time.NewTicker(pingPeriod)
	defer ticker.Stop()
	expiryTimer := time.NewTimer(time.Until(sessionExpiresAt))
	defer expiryTimer.Stop()
	for {
		select {
		case payload, ok := <-client.Send():
			if !ok {
				return nil
			}
			_ = conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := writeTextFrame(rw, payload); err != nil {
				return err
			}
			if err := rw.Flush(); err != nil {
				return err
			}
		case <-ticker.C:
			_ = conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := writePingFrame(rw); err != nil {
				return err
			}
			if err := rw.Flush(); err != nil {
				return err
			}
		case payload := <-pongs:
			_ = conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := writePongFrame(rw, payload); err != nil {
				return err
			}
			if err := rw.Flush(); err != nil {
				return err
			}
		case <-expiryTimer.C:
			return nil
		case <-done:
			return nil
		case <-r.Context().Done():
			return r.Context().Err()
		}
	}
}

func writePingFrame(w io.Writer) error {
	// FIN bit set, opcode 0x9 (ping), zero-length payload. Server->client frames
	// are never masked (RFC 6455 §5.1).
	_, err := w.Write([]byte{0x89, 0x00})
	return err
}

func writePongFrame(w io.Writer, payload []byte) error {
	if len(payload) > 125 {
		return errors.New("control frame payload too large")
	}
	if _, err := w.Write([]byte{0x8a, byte(len(payload))}); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func originAllowed(r *http.Request) bool {
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	if origin == "" {
		// Non-browser clients (mobile/desktop) omit Origin; accept.
		return true
	}
	originURL, err := url.Parse(origin)
	if err != nil || originURL.Host == "" {
		return false
	}
	return strings.EqualFold(originURL.Host, r.Host)
}

func websocketAccept(key string) string {
	sum := sha1.Sum([]byte(key + websocketGUID))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func writeTextFrame(w io.Writer, payload []byte) error {
	header := []byte{0x81}
	switch {
	case len(payload) <= 125:
		header = append(header, byte(len(payload)))
	case len(payload) <= 65535:
		header = append(header, 126, 0, 0)
		binary.BigEndian.PutUint16(header[2:], uint16(len(payload)))
	default:
		header = append(header, 127, 0, 0, 0, 0, 0, 0, 0, 0)
		binary.BigEndian.PutUint64(header[2:], uint64(len(payload)))
	}
	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func drainClientFrames(conn net.Conn, done chan<- struct{}, pongs chan<- []byte) {
	defer close(done)
	reader := bufio.NewReader(conn)
	_ = conn.SetReadDeadline(time.Now().Add(pongWait))
	for {
		first, err := reader.ReadByte()
		if err != nil {
			return
		}
		second, err := reader.ReadByte()
		if err != nil {
			return
		}
		opcode := first & 0x0f
		fin := first&0x80 != 0
		if first&0x70 != 0 || (!fin && opcode >= 0x8) {
			return
		}
		masked := second&0x80 != 0
		// RFC 6455 §5.1: client frames MUST be masked. Close on violation.
		if !masked {
			return
		}
		length := int64(second & 0x7f)
		switch length {
		case 126:
			var buf [2]byte
			if _, err := io.ReadFull(reader, buf[:]); err != nil {
				return
			}
			length = int64(binary.BigEndian.Uint16(buf[:]))
		case 127:
			var buf [8]byte
			if _, err := io.ReadFull(reader, buf[:]); err != nil {
				return
			}
			length = int64(binary.BigEndian.Uint64(buf[:]))
		}
		if length < 0 || length > maxFrameSize {
			return
		}
		if opcode >= 0x8 && length > 125 {
			return
		}
		var mask [4]byte
		if _, err := io.ReadFull(reader, mask[:]); err != nil {
			return
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(reader, payload); err != nil {
			return
		}
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
		if opcode == 0x8 {
			return
		}
		if opcode == 0x9 {
			select {
			case pongs <- payload:
			default:
				return
			}
		}
		// A complete frame (data, ping, or pong) proves the peer is alive, so
		// extend the read deadline. Compliant WebSocket clients answer our pings
		// with pongs automatically, which keeps this refreshed on idle links.
		_ = conn.SetReadDeadline(time.Now().Add(pongWait))
	}
}
