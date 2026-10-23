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
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/config"
)

// TestSmokeLoadAgainstInProcessServer keeps the tool honest: it seeds the
// smoke profile through the real handler, runs a short load with sockets,
// attachments and catch-up, and checks that nothing failed or went missing.
func TestSmokeLoadAgainstInProcessServer(t *testing.T) {
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
	opts := options{Profile: profiles["smoke"], Online: profiles["smoke"].Accounts, Rates: []float64{20, 60},
		Warmup: 500 * time.Millisecond, Duration: 2 * time.Second, Seed: 1, Verify: true, Companions: 0.5, Cold: 0.5}
	var progress bytes.Buffer
	result, err := execute(context.Background(), target, "test-setup-token", opts, &progress)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Steps) != 2 {
		t.Fatalf("steps = %d, want 2", len(result.Steps))
	}
	for _, step := range result.Steps {
		for _, op := range step.Ops {
			if op.Errors+op.ClientErrors+op.RateLimited > 0 {
				t.Fatalf("%s failed at %.0f/min: %+v", op.Op, step.Rate, op)
			}
		}
		for _, op := range []int{opSend, opSync, opDelivery} {
			if step.Ops[op].Count == 0 {
				t.Fatalf("no %s samples at %.0f/min: %+v", opNames[op], step.Rate, step.Ops)
			}
		}
	}
	if result.Steps[1].Ops[opSend].Count <= result.Steps[0].Ops[opSend].Count {
		t.Fatalf("a higher rate did not send more: %d then %d", result.Steps[0].Ops[opSend].Count, result.Steps[1].Ops[opSend].Count)
	}
	if result.Verify == nil || result.Verify.Checked == 0 || result.Verify.Missing != 0 || result.Verify.Errors != 0 {
		t.Fatalf("verify = %+v", result.Verify)
	}
	var report bytes.Buffer
	printReport(&report, result)
	if strings.Contains(report.String()+progress.String(), "test-setup-token") {
		t.Fatal("the setup token reached the report")
	}
}

func TestTargetMustBeLocalUnlessAllowed(t *testing.T) {
	for _, raw := range []string{"http://127.0.0.1:8080", "http://localhost:8080", "http://10.0.0.5", "https://192.168.1.2"} {
		if _, err := checkTarget(raw, false); err != nil {
			t.Fatalf("%s refused: %v", raw, err)
		}
	}
	for _, raw := range []string{"http://198.51.100.7", "https://chat.example.org", "ftp://127.0.0.1"} {
		if _, err := checkTarget(raw, false); err == nil {
			t.Fatalf("%s accepted without -allow-remote", raw)
		}
	}
	if _, err := checkTarget("https://chat.example.org", true); err != nil {
		t.Fatal(err)
	}
}

func TestTimelineMeasuresOutage(t *testing.T) {
	var samples []sample
	for second := 0; second < 10; second++ {
		result := outcomeOK
		if second >= 3 && second < 6 {
			result = outcomeTransportError
		}
		samples = append(samples, sample{at: time.Duration(second) * time.Second, op: opSend, result: result})
	}
	got := timeline(samples)
	if got.LongestOutageS != 3 || got.FirstErrorAtS != 3 || got.RecoveredAfterS != 3 || got.ErrorSeconds != 3 {
		t.Fatalf("timeline = %+v", got)
	}
}
