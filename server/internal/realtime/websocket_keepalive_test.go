package realtime

import (
	"bufio"
	"context"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// scaledKeepalive is the production keepalive relation at 1/div of its size,
// so the tests run in seconds yet check the relation that ships.
func scaledKeepalive(div time.Duration) keepalive {
	return keepalive{pingPeriod: pingPeriod / div, pongWait: pongWait / div, writeWait: writeWait / div}
}

// serveOverPipe runs serveConnWithKeepalive against an in-memory peer. The
// returned channel receives serveConn's result when it ends.
func serveOverPipe(t *testing.T, k keepalive, outbound <-chan []byte) (net.Conn, <-chan error) {
	t.Helper()
	serverConn, clientConn := net.Pipe()
	rw := bufio.NewReadWriter(bufio.NewReader(serverConn), bufio.NewWriter(serverConn))
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		result <- serveConnWithKeepalive(ctx, serverConn, rw, outbound, time.Now().Add(time.Hour), false, k)
		_ = serverConn.Close()
	}()
	t.Cleanup(func() {
		cancel()
		_ = clientConn.Close()
	})
	return clientConn, result
}

// A peer that receives slowly but answers every ping is healthy: a ping
// queued behind an outbound write that takes nearly writeWait still leaves
// time for the pong (VAL-239).
func TestKeepaliveSlowButHealthyPeerStaysConnected(t *testing.T) {
	k := scaledKeepalive(60) // 500ms ping, 1s pong wait, 166ms write wait
	outbound := make(chan []byte, 64)
	stopFeeding := make(chan struct{})
	t.Cleanup(func() { close(stopFeeding) })
	go func() {
		for {
			select {
			case outbound <- []byte(`{"version":"v1","type":"test"}`):
				time.Sleep(10 * time.Millisecond)
			case <-stopFeeding:
				return
			}
		}
	}()
	client, result := serveOverPipe(t, k, outbound)
	reader := bufio.NewReader(client)
	var pings atomic.Int32
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		for {
			frame, err := readServerFrame(reader)
			if err != nil {
				return
			}
			// Slow: close to, but under, the write wait per frame.
			time.Sleep(k.writeWait * 3 / 5)
			if frame.opcode == opPing {
				pings.Add(1)
				if _, err := client.Write(maskedClientFrame(opPong, frame.payload)); err != nil {
					return
				}
			}
		}
	}()
	select {
	case err := <-result:
		t.Fatalf("a slow but responsive peer was disconnected after %d pings: %v", pings.Load(), err)
	case <-time.After(3*k.pingPeriod + k.pongWait/2):
	}
	if pings.Load() < 3 {
		t.Fatalf("only %d pings reached the peer", pings.Load())
	}
}

// A peer that reads every frame at once but never sends one is reaped by the
// read deadline: no server write, ping writes included, renews it (VAL-305).
func TestKeepaliveReadingButSilentPeerIsReapedByTheReadDeadline(t *testing.T) {
	k := keepalive{pingPeriod: 200 * time.Millisecond, pongWait: time.Second, writeWait: 200 * time.Millisecond}
	client, result := serveOverPipe(t, k, make(chan []byte))
	started := time.Now()
	var pings atomic.Int32
	go func() {
		reader := bufio.NewReader(client)
		for {
			frame, err := readServerFrame(reader)
			if err != nil {
				return
			}
			if frame.opcode == opPing {
				pings.Add(1)
			}
		}
	}()
	select {
	case err := <-result:
		elapsed := time.Since(started)
		if err != nil {
			t.Fatalf("serveConn ended with %v, want the read-deadline path (nil)", err)
		}
		if elapsed < k.pongWait-100*time.Millisecond || elapsed > k.pongWait+500*time.Millisecond {
			t.Fatalf("reaped after %s, want about pongWait (%s)", elapsed, k.pongWait)
		}
		if pings.Load() < 2 {
			t.Fatalf("peer saw %d pings, want at least 2", pings.Load())
		}
	case <-time.After(k.pongWait + 2*time.Second):
		t.Fatalf("a peer that read %d pings and never answered was not reaped", pings.Load())
	}
}

// A peer that neither reads nor writes is reaped within a bounded time.
func TestKeepaliveSilentPeerIsReaped(t *testing.T) {
	k := keepalive{pingPeriod: 300 * time.Millisecond, pongWait: time.Second, writeWait: 200 * time.Millisecond}
	_, result := serveOverPipe(t, k, make(chan []byte))
	select {
	case <-result:
	case <-time.After(k.pongWait + k.writeWait + 500*time.Millisecond):
		t.Fatal("a fully silent peer was not reaped")
	}
}

// The time left for a pong after a ping must outlast a delayed outbound write
// plus the ping's own write.
func TestKeepaliveProductionTimingRelation(t *testing.T) {
	if got, need := pongWait-pingPeriod, 2*writeWait; got <= need {
		t.Fatalf("pongWait-pingPeriod = %s, want more than 2*writeWait = %s", got, need)
	}
	if productionKeepalive != (keepalive{pingPeriod: pingPeriod, pongWait: pongWait, writeWait: writeWait}) {
		t.Fatal("serveConn does not use the production timings")
	}
}
