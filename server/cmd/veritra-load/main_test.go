package main

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"testing"
	"time"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/config"
)

// TestGroupSizeFlags: the C8 profile is one group of every account, and
// -group-size resizes it, raising the account count to fit.
func TestGroupSizeFlags(t *testing.T) {
	base := []string{"-target", "http://127.0.0.1:1", "-setup-token-file", "token"}
	opts, err := parseOptions(append(base, "-profile", "c8"), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if p := opts.Profile; p.Accounts != 500 || p.GroupSize != 500 || p.Groups != 1 || p.DMs != 0 || p.Attachments != 0 {
		t.Fatalf("c8 profile = %+v", p)
	}
	opts, err = parseOptions(append(base, "-profile", "c8", "-group-size", "250"), io.Discard)
	if err != nil || opts.Profile.GroupSize != 250 || opts.Profile.Accounts != 500 || opts.Online != 500 {
		t.Fatalf("-group-size 250: %+v, %v", opts.Profile, err)
	}
	opts, err = parseOptions(append(base, "-profile", "s", "-group-size", "120", "-groups", "2"), io.Discard)
	if err != nil || opts.Profile.Accounts != 120 || opts.Profile.GroupSize != 120 || opts.Profile.Groups != 2 {
		t.Fatalf("-group-size past the accounts: %+v, %v", opts.Profile, err)
	}
	if _, err := parseOptions(append(base, "-profile", "c8", "-accounts", "100"), io.Discard); err == nil {
		t.Fatal("a group larger than the account count was accepted")
	}
}

// TestSeedsAGroupLargerThanOneCreateRequest: the server takes at most 100
// other members when a conversation is created, so a C8-sized group is
// finished through the member route. Every account must end up a member and
// receive the group's messages.
func TestSeedsAGroupLargerThanOneCreateRequest(t *testing.T) {
	if testing.Short() {
		t.Skip("load smoke test")
	}
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
	defer application.Close()
	server := httptest.NewServer(application.Handler())
	defer server.Close()
	target, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	p := profiles["c8"]
	p.Accounts, p.GroupSize, p.History = 105, 105, 10
	opts := options{Profile: p, Online: 105, Rates: []float64{2}, Warmup: 300 * time.Millisecond,
		Duration: 6 * time.Second, Seed: 3, Verify: true, DeliveryDeadline: defaultDeliveryDeadline}
	var progress bytes.Buffer
	result, err := execute(context.Background(), target, "test-setup-token", opts, &progress)
	if err != nil {
		t.Fatal(err)
	}
	if result.Verify == nil || result.Verify.Missing != 0 || result.Verify.Errors != 0 {
		t.Fatalf("verify = %+v", result.Verify)
	}
	// Every account is online, so the five added through the member route
	// send into the group; a non-member would be refused (4xx).
	send := result.Steps[0].Ops[opSend]
	if send.Count == 0 || send.Errors+send.ClientErrors > 0 {
		t.Fatalf("sends = %+v", send)
	}
}
