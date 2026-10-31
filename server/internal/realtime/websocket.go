package realtime

import (
	"bufio"
	"context"
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
	"unicode/utf8"
)

// Inbound parser bounds (RFC 6455). The sync socket is server->client push;
// clients send only control frames, so inbound data messages are read,
// validated and discarded. The bounds below are deliberately tight.
const (
	websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

	// maxClientMessageSize bounds one inbound data frame payload and the sum
	// of a fragmented message's payloads. Larger input closes with 1009.
	maxClientMessageSize = 64 << 10
	// maxControlPayload is the RFC 6455 §5.5 control-frame payload limit.
	maxControlPayload = 125
	// maxQueuedPongs bounds pending pong replies. When full, the oldest
	// pending ping is dropped (RFC 6455 §5.5.3 allows answering only the
	// most recent ping), so a ping flood cannot grow memory.
	maxQueuedPongs = 16

	// Keepalive parameters. We ping the client every pingPeriod and require a
	// complete frame (a pong or anything else) within pongWait, so a half-open
	// or slow-drip peer is reaped instead of pinning a goroutine and
	// subscription indefinitely. writeWait bounds every write.
	//
	// A pong has pongWait-pingPeriod to come back after its ping is due. The
	// ping can sit behind one outbound write (up to writeWait) and then needs
	// its own write (up to writeWait) before the peer can even see it, so the
	// difference must exceed 2*writeWait with room to spare for the round
	// trip; a test asserts it. Half of pongWait leaves 30s against 20s.
	writeWait  = 10 * time.Second
	pongWait   = 60 * time.Second
	pingPeriod = pongWait / 2
	// closeWait bounds how long the server lingers for the peer's close
	// after sending its own close frame.
	closeWait = time.Second
)

// RFC 6455 §7.4.1 close status codes sent by the server.
const (
	closeGoingAway       uint16 = 1001
	closeProtocolError   uint16 = 1002
	closeInvalidPayload  uint16 = 1007
	closePolicyViolation uint16 = 1008
	closeMessageTooBig   uint16 = 1009
)

const (
	opContinuation byte = 0x0
	opText         byte = 0x1
	opBinary       byte = 0x2
	opClose        byte = 0x8
	opPing         byte = 0x9
	opPong         byte = 0xa
)

// closeReply is the close frame the server sends after the reader stops.
// send=false means the transport failed (EOF, timeout) and no frame is sent.
// code==0 with send=true echoes an empty close body.
type closeReply struct {
	send bool
	code uint16
}

// inboundMessage is a complete, validated data message. It is only produced
// when a message sink is configured (the protocol test harness); production
// discards inbound data.
type inboundMessage struct {
	opcode  byte
	payload []byte
}

func ServeWebSocket(w http.ResponseWriter, r *http.Request, client *Client, sessionExpiresAt time.Time, unregister func()) error {
	defer unregister()
	conn, rw, err := upgradeWebSocket(w, r)
	if err != nil {
		return err
	}
	defer conn.Close()
	return serveConn(r.Context(), conn, rw, client.Send(), sessionExpiresAt, false)
}

// upgradeWebSocket validates the RFC 6455 §4.2.1 handshake, hijacks the
// connection and writes the 101 response.
func upgradeWebSocket(w http.ResponseWriter, r *http.Request) (net.Conn, *bufio.ReadWriter, error) {
	if !isWebSocketUpgrade(r) {
		http.Error(w, "websocket upgrade required", http.StatusUpgradeRequired)
		return nil, nil, errors.New("websocket upgrade required")
	}
	if !originAllowed(r) {
		http.Error(w, "origin not allowed", http.StatusForbidden)
		return nil, nil, errors.New("origin not allowed")
	}
	key := strings.TrimSpace(r.Header.Get("Sec-WebSocket-Key"))
	decodedKey, err := base64.StdEncoding.DecodeString(key)
	if err != nil || len(decodedKey) != 16 {
		http.Error(w, "missing websocket key", http.StatusBadRequest)
		return nil, nil, errors.New("missing websocket key")
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijacking unsupported", http.StatusInternalServerError)
		return nil, nil, errors.New("hijacking unsupported")
	}
	conn, rw, err := hijacker.Hijack()
	if err != nil {
		return nil, nil, err
	}
	// After hijack the http.Server no longer manages this connection. Set an
	// explicit write deadline for the handshake (and refresh it before every
	// subsequent write) rather than leaving the server's timeouts in place
	// (which would kill the long-lived socket) or clearing them entirely
	// (which would let a dead peer pin this goroutine forever).
	_ = conn.SetWriteDeadline(time.Now().Add(writeWait))
	accept := websocketAccept(key)
	if _, err := fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept); err != nil {
		conn.Close()
		return nil, nil, err
	}
	if err := rw.Flush(); err != nil {
		conn.Close()
		return nil, nil, err
	}
	return conn, rw, nil
}

// serveConn runs the single writer loop and the frame reader. echo is only
// set by the protocol test harness; it writes inbound data messages back.
func serveConn(ctx context.Context, conn net.Conn, rw *bufio.ReadWriter, outbound <-chan []byte, sessionExpiresAt time.Time, echo bool) error {
	return serveConnWithKeepalive(ctx, conn, rw, outbound, sessionExpiresAt, echo, productionKeepalive)
}

// keepalive holds the timings of the liveness protocol, so tests can run it
// at a fraction of the production scale.
type keepalive struct {
	pingPeriod time.Duration // how often the server pings
	pongWait   time.Duration // how long the peer may send nothing
	writeWait  time.Duration // bound on every write
}

var productionKeepalive = keepalive{pingPeriod: pingPeriod, pongWait: pongWait, writeWait: writeWait}

func serveConnWithKeepalive(ctx context.Context, conn net.Conn, rw *bufio.ReadWriter, outbound <-chan []byte, sessionExpiresAt time.Time, echo bool, k keepalive) error {
	done := make(chan struct{})
	stop := make(chan struct{})
	defer close(stop)
	pongs := make(chan []byte, maxQueuedPongs)
	var inbound chan inboundMessage
	if echo {
		inbound = make(chan inboundMessage)
	}
	reader := &frameReader{
		// The hijacked bufio.Reader may already hold client bytes that
		// arrived with the handshake; read through it, never conn directly.
		r:           rw.Reader,
		setDeadline: conn.SetReadDeadline,
		pongs:       pongs,
		messages:    inbound,
		stop:        stop,
		pongWait:    k.pongWait,
	}
	var reply closeReply
	go func() {
		defer close(done)
		reply = reader.run()
	}()
	ticker := time.NewTicker(k.pingPeriod)
	defer ticker.Stop()
	expiryTimer := time.NewTimer(time.Until(sessionExpiresAt))
	defer expiryTimer.Stop()
	write := func(frame func(io.Writer) error) error {
		_ = conn.SetWriteDeadline(time.Now().Add(k.writeWait))
		if err := frame(rw); err != nil {
			return err
		}
		return rw.Flush()
	}
	flushPongs := func() error {
		for {
			select {
			case payload := <-pongs:
				if err := write(func(w io.Writer) error { return writePongFrame(w, payload) }); err != nil {
					return err
				}
			default:
				return nil
			}
		}
	}
	readerDone := false
	// closeHandshake sends a close frame, half-closes the TCP stream and
	// briefly lingers for the peer's close or EOF (bounded by closeWait and
	// maxClientMessageSize) so unread client bytes do not turn the close into
	// a TCP reset that discards our close frame.
	closeHandshake := func(code uint16) {
		if err := write(func(w io.Writer) error { return writeCloseFrame(w, code) }); err != nil {
			return
		}
		if halfCloser, ok := conn.(interface{ CloseWrite() error }); ok {
			_ = halfCloser.CloseWrite()
		}
		_ = conn.SetReadDeadline(time.Now().Add(closeWait))
		if readerDone {
			_, _ = io.Copy(io.Discard, io.LimitReader(rw.Reader, maxClientMessageSize))
			return
		}
		timer := time.NewTimer(closeWait)
		defer timer.Stop()
		select {
		case <-done:
		case <-timer.C:
		}
	}
	for {
		// A due ping goes first. Go's select picks among ready cases at
		// random, so a steady stream of outbound payloads could otherwise
		// postpone the ping until the peer's read deadline passes.
		select {
		case <-ticker.C:
			if err := write(writePingFrame); err != nil {
				return err
			}
		default:
		}
		select {
		case payload, ok := <-outbound:
			if !ok {
				closeHandshake(closeGoingAway)
				return nil
			}
			if err := write(func(w io.Writer) error { return writeFrame(w, opText, payload) }); err != nil {
				return err
			}
		case message := <-inbound:
			// Keep wire order: pings read before this message are answered first.
			if err := flushPongs(); err != nil {
				return err
			}
			if err := write(func(w io.Writer) error { return writeFrame(w, message.opcode, message.payload) }); err != nil {
				return err
			}
		case <-ticker.C:
			if err := write(writePingFrame); err != nil {
				return err
			}
		case payload := <-pongs:
			if err := write(func(w io.Writer) error { return writePongFrame(w, payload) }); err != nil {
				return err
			}
		case <-expiryTimer.C:
			closeHandshake(closePolicyViolation)
			return nil
		case <-done:
			readerDone = true
			// Answer pings that arrived before the peer's close.
			if err := flushPongs(); err != nil {
				return err
			}
			if reply.send {
				closeHandshake(reply.code)
			}
			return nil
		case <-ctx.Done():
			closeHandshake(closeGoingAway)
			return ctx.Err()
		}
	}
}

func isWebSocketUpgrade(r *http.Request) bool {
	if !strings.EqualFold(strings.TrimSpace(r.Header.Get("Upgrade")), "websocket") ||
		strings.TrimSpace(r.Header.Get("Sec-WebSocket-Version")) != "13" {
		return false
	}
	for _, token := range strings.Split(r.Header.Get("Connection"), ",") {
		if strings.EqualFold(strings.TrimSpace(token), "upgrade") {
			return true
		}
	}
	return false
}

func originAllowed(r *http.Request) bool {
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	if origin == "" {
		// Non-browser clients (mobile/desktop) omit Origin; accept.
		return true
	}
	originURL, err := url.Parse(origin)
	if err != nil || originURL.Host == "" || originURL.User != nil ||
		(originURL.Scheme != "http" && originURL.Scheme != "https") ||
		originURL.Path != "" || originURL.RawQuery != "" || originURL.Fragment != "" {
		return false
	}
	return strings.EqualFold(originURL.Host, r.Host)
}

func websocketAccept(key string) string {
	sum := sha1.Sum([]byte(key + websocketGUID))
	return base64.StdEncoding.EncodeToString(sum[:])
}

// writeFrame writes one unfragmented, unmasked server frame (RFC 6455 §5.1:
// server frames are never masked).
func writeFrame(w io.Writer, opcode byte, payload []byte) error {
	if opcode >= opClose && len(payload) > maxControlPayload {
		return errors.New("control frame payload too large")
	}
	header := []byte{0x80 | opcode}
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

func writeTextFrame(w io.Writer, payload []byte) error {
	return writeFrame(w, opText, payload)
}

func writePingFrame(w io.Writer) error {
	return writeFrame(w, opPing, nil)
}

func writePongFrame(w io.Writer, payload []byte) error {
	return writeFrame(w, opPong, payload)
}

// writeCloseFrame writes a close frame with status code, or an empty body
// when code is 0. No reason text is sent, so nothing dynamic leaves the server.
func writeCloseFrame(w io.Writer, code uint16) error {
	if code == 0 {
		return writeFrame(w, opClose, nil)
	}
	var body [2]byte
	binary.BigEndian.PutUint16(body[:], code)
	return writeFrame(w, opClose, body[:])
}

// frameReader parses masked client frames until the peer closes, the
// transport fails, or the input violates a bound. It never logs or retains
// payloads beyond the current message.
type frameReader struct {
	r           *bufio.Reader
	setDeadline func(time.Time) error
	// pongs receives ping payloads to answer; sends never block.
	pongs chan []byte
	// messages, when non-nil, receives complete data messages (test harness
	// echo only). Sends abort when stop is closed.
	messages chan<- inboundMessage
	stop     <-chan struct{}
	// pongWait is how long the peer may stay silent; zero means the
	// package default.
	pongWait time.Duration
}

func (f *frameReader) run() closeReply {
	wait := f.pongWait
	if wait <= 0 {
		wait = pongWait
	}
	_ = f.setDeadline(time.Now().Add(wait))
	var fragmentedOpcode byte
	var fragmentedPayload []byte
	utf8Checked := 0
	for {
		var head [2]byte
		if _, err := io.ReadFull(f.r, head[:]); err != nil {
			return closeReply{}
		}
		first, second := head[0], head[1]
		opcode := first & 0x0f
		fin := first&0x80 != 0
		// RSV1-3 must be zero: no extensions are negotiated (§5.2).
		if first&0x70 != 0 || !validOpcode(opcode) {
			return closeReply{send: true, code: closeProtocolError}
		}
		isControl := opcode >= opClose
		// Control frames must not be fragmented (§5.5); continuation needs an
		// open message and a new data frame needs none (§5.4).
		if isControl && !fin ||
			opcode == opContinuation && fragmentedOpcode == 0 ||
			(opcode == opText || opcode == opBinary) && fragmentedOpcode != 0 {
			return closeReply{send: true, code: closeProtocolError}
		}
		// Client frames must be masked (§5.1).
		if second&0x80 == 0 {
			return closeReply{send: true, code: closeProtocolError}
		}
		length := uint64(second & 0x7f)
		switch length {
		case 126:
			var buf [2]byte
			if _, err := io.ReadFull(f.r, buf[:]); err != nil {
				return closeReply{}
			}
			length = uint64(binary.BigEndian.Uint16(buf[:]))
			if length < 126 { // minimal encoding (§5.2)
				return closeReply{send: true, code: closeProtocolError}
			}
		case 127:
			var buf [8]byte
			if _, err := io.ReadFull(f.r, buf[:]); err != nil {
				return closeReply{}
			}
			length = binary.BigEndian.Uint64(buf[:])
			if length>>63 != 0 || length <= 65535 {
				return closeReply{send: true, code: closeProtocolError}
			}
		}
		if isControl && length > maxControlPayload {
			return closeReply{send: true, code: closeProtocolError}
		}
		if length > maxClientMessageSize ||
			opcode == opContinuation && uint64(len(fragmentedPayload))+length > maxClientMessageSize {
			return closeReply{send: true, code: closeMessageTooBig}
		}
		var mask [4]byte
		if _, err := io.ReadFull(f.r, mask[:]); err != nil {
			return closeReply{}
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(f.r, payload); err != nil {
			return closeReply{}
		}
		for i := range payload {
			payload[i] ^= mask[i%4]
		}

		switch opcode {
		case opClose:
			code, ok := parseClosePayload(payload)
			if !ok {
				if len(payload) > 2 && !utf8.Valid(payload[2:]) {
					return closeReply{send: true, code: closeInvalidPayload}
				}
				return closeReply{send: true, code: closeProtocolError}
			}
			return closeReply{send: true, code: code}
		case opPing:
			f.queuePong(payload)
		case opPong:
			// Unsolicited or matching pongs only refresh the deadline.
		case opText, opBinary:
			if fin {
				if opcode == opText && !utf8.Valid(payload) {
					return closeReply{send: true, code: closeInvalidPayload}
				}
				if !f.deliver(opcode, payload) {
					return closeReply{}
				}
			} else {
				fragmentedOpcode = opcode
				fragmentedPayload = append(fragmentedPayload[:0], payload...)
				utf8Checked = 0
			}
		case opContinuation:
			fragmentedPayload = append(fragmentedPayload, payload...)
		}
		if fragmentedOpcode == opText && (opcode == opText || opcode == opContinuation) {
			// Fail fast on invalid UTF-8 at fragment boundaries (§8.1),
			// validating each byte once.
			var ok bool
			utf8Checked, ok = checkUTF8Prefix(fragmentedPayload, utf8Checked)
			if !ok || fin && utf8Checked != len(fragmentedPayload) {
				return closeReply{send: true, code: closeInvalidPayload}
			}
		}
		if opcode == opContinuation && fin {
			message := append([]byte(nil), fragmentedPayload...)
			if !f.deliver(fragmentedOpcode, message) {
				return closeReply{}
			}
			fragmentedOpcode = 0
			fragmentedPayload = fragmentedPayload[:0]
			utf8Checked = 0
		}
		// A complete frame (data, ping, or pong) proves the peer is alive, so
		// extend the read deadline. Compliant WebSocket clients answer our pings
		// with pongs automatically, which keeps this refreshed on idle links.
		// Only inbound frames renew it: nothing the server writes does.
		_ = f.setDeadline(time.Now().Add(wait))
	}
}

// queuePong queues a pong reply without blocking, dropping the oldest
// pending one when the queue is full.
func (f *frameReader) queuePong(payload []byte) {
	for {
		select {
		case f.pongs <- payload:
			return
		default:
		}
		select {
		case <-f.pongs:
		default:
		}
	}
}

// deliver hands a complete data message to the sink, if any. It reports
// false when the connection is stopping.
func (f *frameReader) deliver(opcode byte, payload []byte) bool {
	if f.messages == nil {
		return true
	}
	select {
	case f.messages <- inboundMessage{opcode: opcode, payload: payload}:
		return true
	case <-f.stop:
		return false
	}
}

func validOpcode(opcode byte) bool {
	return opcode <= opBinary || opcode >= opClose && opcode <= opPong
}

// parseClosePayload validates a received close body (§5.5.1, §7.4). It
// returns the code to echo (0 for an empty body).
func parseClosePayload(payload []byte) (uint16, bool) {
	if len(payload) == 0 {
		return 0, true
	}
	if len(payload) == 1 {
		return 0, false
	}
	code := binary.BigEndian.Uint16(payload[:2])
	if !validCloseCode(code) || !utf8.Valid(payload[2:]) {
		return 0, false
	}
	return code, true
}

// validCloseCode accepts codes an endpoint may send on the wire: the RFC 6455
// defined codes, the IANA-registered 1012-1014, and the 3000-4999
// registered/private range. 1004-1006, 1015 and all others are rejected.
func validCloseCode(code uint16) bool {
	return code >= 3000 && code <= 4999 ||
		code >= 1000 && code <= 1003 ||
		code >= 1007 && code <= 1014
}

// checkUTF8Prefix validates b[from:] as UTF-8 that may end inside a code
// point. It returns the offset of the first unconsumed byte (the start of a
// trailing incomplete sequence, or len(b)) and whether the input could still
// be completed into valid UTF-8.
func checkUTF8Prefix(b []byte, from int) (int, bool) {
	i := from
	for i < len(b) {
		if b[i] < utf8.RuneSelf {
			i++
			continue
		}
		if !utf8.FullRune(b[i:]) {
			return i, validUTF8Start(b[i:])
		}
		r, size := utf8.DecodeRune(b[i:])
		if r == utf8.RuneError && size == 1 {
			return i, false
		}
		i += size
	}
	return i, true
}

// validUTF8Start reports whether an incomplete multi-byte sequence can be
// completed into a valid code point. Only the second byte has
// lead-dependent ranges; later bytes are always 0x80-0xBF.
func validUTF8Start(tail []byte) bool {
	candidates := [][]byte{tail}
	if len(tail) == 1 {
		candidates = [][]byte{{tail[0], 0x80}, {tail[0], 0x90}, {tail[0], 0xa0}}
	}
	for _, candidate := range candidates {
		probe := append([]byte(nil), candidate...)
		for len(probe) < utf8.UTFMax && !utf8.FullRune(probe) {
			probe = append(probe, 0x80)
		}
		r, size := utf8.DecodeRune(probe)
		if !(r == utf8.RuneError && size == 1) && size == len(probe) {
			return true
		}
	}
	return false
}
