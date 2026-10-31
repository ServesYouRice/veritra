package main

import (
	"context"
	"io"
	"log/slog"
	mrand "math/rand/v2"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/config"
)

// inProcessTarget starts the real server in process, trusting loopback as
// a proxy so each simulated client keeps its own address.
func inProcessTarget(t *testing.T) *url.URL {
	t.Helper()
	dir := t.TempDir()
	_, loopback, _ := net.ParseCIDR("127.0.0.1/32")
	application, err := app.New(context.Background(), config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath: filepath.Join(dir, "blobs"), InstanceName: "load test", SetupToken: "test-setup-token",
		TrustedProxies: []*net.IPNet{loopback}, PasswordCost: config.MinPasswordCost,
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = application.Close() })
	server := httptest.NewServer(application.Handler())
	t.Cleanup(server.Close)
	target, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	return target
}

// TestCompanionsAreSeparatelyLinkedDevices: a companion client runs on its
// own linked device, with its own token, device ID and address, and the
// server lists two devices for the account. The companion can open the
// sync socket and read like the primary.
func TestCompanionsAreSeparatelyLinkedDevices(t *testing.T) {
	if testing.Short() {
		t.Skip("seeds an in-process server")
	}
	target := inProcessTarget(t)
	p := profiles["smoke"]
	p.History, p.Attachments = 4, 1
	w := &world{client: newAPIClient(target, 16), base: target, profile: p, rec: newRecorder()}
	companions := []bool{true, false, true}
	var progress strings.Builder
	if err := w.seed(context.Background(), "test-setup-token", mrand.New(mrand.NewPCG(1, 2)), &progress, companions); err != nil {
		t.Fatal(err)
	}
	for i := range w.devices {
		primary, companion := w.devices[i], w.companions[i]
		if i >= len(companions) || !companions[i] {
			if companion != nil {
				t.Fatalf("account %d got a companion it was not planned", i)
			}
			continue
		}
		if companion == nil {
			t.Fatalf("account %d has no companion device", i)
		}
		if companion.deviceID == primary.deviceID || companion.token == primary.token || companion.ip == primary.ip ||
			companion.accountID != primary.accountID || companion.index != primary.index {
			t.Fatalf("account %d companion is not a separate device of the same account", i)
		}
		var listed struct {
			Devices []struct {
				ID string `json:"id"`
			} `json:"devices"`
		}
		if err := expect(w.client.json(context.Background(), http.MethodGet, "/api/v1/devices/me", primary, "", nil, &listed, nil)); err != nil {
			t.Fatal(err)
		}
		if len(listed.Devices) != 2 {
			t.Fatalf("account %d lists %d devices, want 2", i, len(listed.Devices))
		}
		socket, err := dialSync(context.Background(), target, companion)
		if err != nil {
			t.Fatalf("companion socket: %v", err)
		}
		socket.close()
		for _, path := range []string{"/api/v1/sync/events?after=0&limit=1", "/api/v1/conversations?limit=100",
			"/api/v1/conversations/" + url.PathEscape(w.convs[w.byDevice[i][0]].id) + "/messages?limit=50"} {
			status, _, err := w.client.do(context.Background(), request{method: http.MethodGet, path: path, dev: companion}, nil)
			if err := expect(status, err, http.StatusOK); err != nil {
				t.Fatalf("companion GET %s: %v", strings.SplitN(path, "?", 2)[0], err)
			}
		}
	}
	for _, dev := range w.companions {
		if dev != nil && strings.Contains(progress.String(), dev.token) {
			t.Fatal("a companion token reached the progress output")
		}
	}
}
