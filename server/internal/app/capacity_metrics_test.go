package app

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/backupstatus"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/httpapi"
	"private-messenger/server/internal/push"
)

// metricLine matches one sample: name, optional label set, value.
var metricLine = regexp.MustCompile(`^([a-z_]+)(\{.*\})? (-?[0-9.e+]+|\+Inf)$`)

var metricLabel = regexp.MustCompile(`([a-z_]+)="((?:[^"\\]|\\.)*)"`)

// allowedLabelValues is the closed set every label must come from. route
// is checked separately: it must be a registered ServeMux pattern.
var allowedLabelValues = map[string]map[string]bool{
	"status_class": {"1xx": true, "2xx": true, "3xx": true, "4xx": true, "5xx": true},
	"provider":     {"apns": true, "fcm": true, "webpush": true},
	"result":       {"attempted": true, "delivered": true, "failed": true, "abandoned": true},
	"pool":         {"writer": true, "reader": true},
	"volume":       {"database": true, "blobs": true},
	"component":    {"database": true, "wal": true, "blobs": true},
	"scope":        {"general": true, "auth": true, "enrollment": true, "account": true, "signed_in": true},
	"reason":       {"limit": true, "draining": true},
	"limit": {"storage": true, "blobs": true, "devices": true, "device_links": true, "conversations": true,
		"conversation_members": true, "key_package_claims": true, "deliveries": true, "write_bytes": true, "disk": true},
}

var routePattern = regexp.MustCompile(`^(unmatched|(GET|POST|PUT|PATCH|DELETE) )?/[a-z0-9/{}_.-]*$`)

// assertClosedLabels fails when any label key or value in body falls outside
// the closed sets above, or when a line is not a well-formed sample.
func assertClosedLabels(t *testing.T, body string) {
	t.Helper()
	for _, line := range strings.Split(strings.TrimSpace(body), "\n") {
		if strings.HasPrefix(line, "# TYPE ") {
			continue
		}
		match := metricLine.FindStringSubmatch(line)
		if match == nil {
			t.Fatalf("malformed metrics line %q", line)
		}
		if !strings.HasPrefix(match[1], "veritra_") {
			t.Fatalf("metric %q lacks the veritra_ prefix", match[1])
		}
		for _, label := range metricLabel.FindAllStringSubmatch(match[2], -1) {
			key, value := label[1], label[2]
			switch key {
			case "le":
				continue
			case "route":
				if value != "unmatched" && !routePattern.MatchString(value) {
					t.Fatalf("route label %q is not a pattern", value)
				}
				continue
			}
			values, ok := allowedLabelValues[key]
			if !ok || !values[value] {
				t.Fatalf("label %s=%q outside its closed set in %q", key, value, line)
			}
		}
	}
}

func TestCapacityMetricsAreAggregateAndClosedLabelled(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	cfg := config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: filepath.Join(dir, "SENTINEL-db", "private-messenger.db"),
		StoragePath: filepath.Join(dir, "SENTINEL-blobs"), InstanceName: "test", EnableMetrics: true,
	}
	var logs bytes.Buffer
	application, err := New(ctx, cfg, slog.New(slog.NewTextHandler(&logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer application.Close()
	// Real writes so the pool and writer histogram have data.
	if _, err := application.Store.SetupRequired(ctx); err != nil {
		t.Fatal(err)
	}
	if err := application.Store.QueueBlobDeletion(ctx, "blob_SENTINEL_storage_key"); err != nil {
		t.Fatal(err)
	}
	if err := backupstatus.RecordDrill(dir, true, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	application.sampleCapacity(ctx)
	application.metrics.record("GET /api/v1/conversations/{id}", 200, time.Millisecond)

	recorder := httptest.NewRecorder()
	application.metrics.handle(recorder, httptest.NewRequest("GET", "/metrics", nil))
	body := recorder.Body.String()
	if strings.Contains(body, "SENTINEL") || strings.Contains(logs.String(), "SENTINEL") {
		t.Fatalf("an identifier or path reached the metrics or logs:\n%s\n%s", body, logs.String())
	}
	assertClosedLabels(t, body)
	for _, want := range []string{
		`veritra_sqlite_pool_waits_total{pool="writer"} `,
		`veritra_sqlite_pool_wait_seconds_total{pool="reader"} `,
		`veritra_sqlite_pool_in_use_connections{pool="writer"} 0`,
		`veritra_sqlite_writer_acquire_duration_seconds_bucket{le="0.001"} `,
		// Sizes are coarse: a small test database rounds down to 0.
		`veritra_storage_bytes{component="database"} 0`,
		`veritra_storage_bytes{component="blobs"} 0`,
		`veritra_storage_filesystem_avail_bytes{volume="database"} `,
		`veritra_storage_filesystem_size_bytes{volume="blobs"} `,
		`veritra_storage_sample_timestamp_seconds `,
		`veritra_backup_last_restore_drill_success 1`,
		`veritra_backup_last_restore_drill_timestamp_seconds `,
		`veritra_realtime_dropped_events_total 0`,
		`veritra_realtime_rejected_connections_total{reason="limit"} 0`,
		`veritra_realtime_rejected_connections_total{reason="draining"} 0`,
		`veritra_rate_limit_rejections_total{scope="auth"} 0`,
		`veritra_push_backlog_oldest_job_timestamp_seconds{provider="webpush"} 0`,
		`veritra_push_send_duration_seconds_count{provider="apns"} 0`,
		`veritra_go_goroutines `,
		`veritra_go_memory_bytes `,
		`veritra_go_heap_live_bytes `,
		`veritra_process_start_time_seconds `,
		`veritra_retention_last_sweep_timestamp_seconds 0`,
		`veritra_http_request_duration_seconds_bucket{route="GET /api/v1/conversations/{id}",le="0.25"} 1`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("metrics output missing %q:\n%s", want, body)
		}
	}
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "veritra_storage_") && !strings.Contains(line, "_timestamp_") && !strings.Contains(line, "_errors_") {
			value, err := strconv.ParseInt(line[strings.LastIndexByte(line, ' ')+1:], 10, 64)
			if err != nil || value%storageGranularity != 0 {
				t.Fatalf("storage gauge is not coarse: %q", line)
			}
		}
	}
	acquire := application.Store.WriterAcquire()
	if acquire.Count == 0 {
		t.Fatal("writer acquisitions were not observed")
	}
}

// A volume that was low and then cannot be probed stays low: a failed probe
// proves nothing about recovery. A successful, not-low probe clears it, and
// a platform whose probe always fails never sets the guard (VAL-206).
func TestSampleCapacityKeepsLowDiskWhenProbeFails(t *testing.T) {
	type probe struct {
		avail, size uint64
		ok          bool
	}
	const gib = 1 << 30
	low := probe{avail: gib / 100, size: 100 * gib, ok: true}
	roomy := probe{avail: 90 * gib, size: 100 * gib, ok: true}
	failing := probe{}

	run := func(t *testing.T, steps [][2]probe, want []bool) {
		t.Helper()
		var current [2]probe
		previous := statFilesystem
		t.Cleanup(func() { statFilesystem = previous })
		calls := 0
		statFilesystem = func(string) (uint64, uint64, bool) {
			p := current[calls%2]
			calls++
			return p.avail, p.size, p.ok
		}
		application := &App{
			Config:  config.Config{DatabasePath: filepath.Join(t.TempDir(), "db", "private-messenger.db"), StoragePath: t.TempDir()},
			metrics: &httpMetrics{},
			Log:     slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)),
		}
		for i, step := range steps {
			current = step
			application.sampleCapacity(context.Background())
			if got := application.lowDisk.Load(); got != want[i] {
				t.Fatalf("sample %d: lowDisk = %v, want %v", i, got, want[i])
			}
		}
	}

	t.Run("failure keeps the guard until a not-low probe", func(t *testing.T) {
		run(t, [][2]probe{{low, roomy}, {failing, roomy}, {failing, failing}, {roomy, roomy}}, []bool{true, true, true, false})
	})
	t.Run("each volume keeps its own state", func(t *testing.T) {
		run(t, [][2]probe{{roomy, low}, {roomy, failing}, {roomy, roomy}}, []bool{true, true, false})
	})
	t.Run("probes that never work leave the guard off", func(t *testing.T) {
		run(t, [][2]probe{{failing, failing}, {failing, failing}}, []bool{false, false})
	})
}

func TestBackupDrillMetricDistinguishesNeverFailedAndPassed(t *testing.T) {
	cases := []struct {
		name   string
		status backupstatus.Status
		ok     bool
		want   string
	}{
		{"never", backupstatus.Status{}, false, "veritra_backup_last_restore_drill_timestamp_seconds 0\n# TYPE veritra_backup_last_restore_drill_success gauge\nveritra_backup_last_restore_drill_success 0\n"},
		{"failed", backupstatus.Status{LastDrillAt: ptrTime(time.Now())}, true, "veritra_backup_last_restore_drill_success 0\n"},
		{"passed", backupstatus.Status{LastDrillAt: ptrTime(time.Now()), LastDrillPassed: true}, true, "veritra_backup_last_restore_drill_success 1\n"},
	}
	for _, tc := range cases {
		metrics := newHTTPMetrics()
		metrics.backupStatus = func() (backupstatus.Status, bool) { return tc.status, tc.ok }
		recorder := httptest.NewRecorder()
		metrics.handle(recorder, httptest.NewRequest("GET", "/metrics", nil))
		if !strings.Contains(recorder.Body.String(), tc.want) {
			t.Fatalf("%s: missing %q in\n%s", tc.name, tc.want, recorder.Body.String())
		}
	}
}

func ptrTime(value time.Time) *time.Time { return &value }

func TestPushSendTimeoutsAndOldestAgeAreCounted(t *testing.T) {
	h := newPushHarness(t, func(ctx context.Context, _ push.Notification) error {
		<-ctx.Done()
		return ctx.Err()
	})
	h.app.pushSendTimeout = 100 * time.Millisecond
	h.seed(t, 1)
	h.exec(t, `UPDATE push_wake_jobs SET created_at = ?`, time.Now().UTC().Add(-90*time.Second).Format(pushTimeLayout))
	start := time.Now()
	h.app.drainPushWakeBatch(context.Background(), pushTestProvider)
	if elapsed := time.Since(start); elapsed < h.app.pushSendTimeout {
		t.Fatalf("stalled send returned after %s, before the %s deadline", elapsed, h.app.pushSendTimeout)
	}
	metric := h.app.metrics.push[pushTestProvider]
	if metric.timeouts.Load() != 1 || metric.failed.Load() != 1 {
		t.Fatalf("timeouts=%d failed=%d", metric.timeouts.Load(), metric.failed.Load())
	}
	if age := time.Now().Unix() - metric.oldestQueuedAt.Load(); age < 89 || age > 120 {
		t.Fatalf("oldest wake job age = %d s, want about 90", age)
	}
	if snapshot := metric.sendDuration.Snapshot(); snapshot.Count != 1 || snapshot.Sum < h.app.pushSendTimeout {
		t.Fatalf("send duration snapshot = %+v", snapshot)
	}
	h.assertPrivate(t)
}

func TestRateLimitRejectionsAreCountedByScope(t *testing.T) {
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver(nil), rateLimits{general: 2, auth: 1, enrollment: 1, account: 2, signedIn: 2})
	if err != nil {
		t.Fatal(err)
	}
	handler := limiter.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	for _, path := range []string{"/api/v1/auth/login", "/api/v1/auth/login", "/api/v1/conversations"} {
		request := httptest.NewRequest("POST", path, nil)
		request.RemoteAddr = "192.0.2.10:1234"
		handler.ServeHTTP(httptest.NewRecorder(), request)
	}
	if got := limiter.rejections[1].Load(); got != 1 {
		t.Fatalf("auth rejections = %d, want 1", got)
	}
	if got := limiter.rejections[0].Load(); got != 1 {
		t.Fatalf("general rejections = %d, want 1", got)
	}
}
