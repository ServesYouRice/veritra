package app

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"private-messenger/server/internal/config"
)

func withFilesystem(t *testing.T, avail, size uint64) {
	t.Helper()
	previous := statFilesystem
	statFilesystem = func(string) (uint64, uint64, bool) { return avail, size, true }
	t.Cleanup(func() { statFilesystem = previous })
}

func TestInstanceStorageDerivesFromTheBlobVolume(t *testing.T) {
	withFilesystem(t, 30<<30, 40<<30)
	t.Setenv("PRIVATE_MESSENGER_BACKUP_KEEP", "")
	cfg, source := ResolveInstanceStorage(config.Config{StoragePath: t.TempDir()})
	if source != "derived" || cfg.Limits.InstanceStorageBytes != 3686<<20 {
		t.Fatalf("40 GiB volume, keep 7: %s %d MiB", source, cfg.Limits.InstanceStorageBytes>>20)
	}
	t.Setenv("PRIVATE_MESSENGER_BACKUP_KEEP", "2")
	if cfg, _ := ResolveInstanceStorage(config.Config{StoragePath: t.TempDir()}); cfg.Limits.InstanceStorageBytes != 7372<<20 {
		t.Fatalf("keep 2: %d MiB", cfg.Limits.InstanceStorageBytes>>20)
	}
	configured := config.Config{Limits: config.Limits{InstanceStorageBytes: 1 << 30}}
	if cfg, source := ResolveInstanceStorage(configured); source != "configured" || cfg.Limits.InstanceStorageBytes != 1<<30 {
		t.Fatalf("configured limit replaced: %s %d", source, cfg.Limits.InstanceStorageBytes)
	}
}

func TestStartupLogsResolvedLimitsAndAccountFitsInstance(t *testing.T) {
	withFilesystem(t, 1<<30, 2<<30) // 2 GiB volume: 184 MiB derived
	dir := t.TempDir()
	var logs bytes.Buffer
	application, err := New(context.Background(), config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: filepath.Join(dir, "db"), StoragePath: filepath.Join(dir, "blobs"),
	}, slog.New(slog.NewTextHandler(&logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer application.Close()
	limits := application.Store.Limits()
	if limits.InstanceStorageBytes != 184<<20 || limits.AccountStorageBytes != limits.InstanceStorageBytes {
		t.Fatalf("limits on a 2 GiB volume = %+v", limits)
	}
	for _, want := range []string{"admission_limits", "instance_storage_mib=184", "instance_storage_source=derived", "account_storage_mib=184"} {
		if !strings.Contains(logs.String(), want) {
			t.Fatalf("startup log lacks %q: %s", want, logs.String())
		}
	}
	if strings.Contains(logs.String(), dir) {
		t.Fatal("startup log names the data directory")
	}
}

func TestLowDiskGuardFollowsTheSampler(t *testing.T) {
	dir := t.TempDir()
	application, err := New(context.Background(), config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: filepath.Join(dir, "db"), StoragePath: filepath.Join(dir, "blobs"),
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer application.Close()
	withFilesystem(t, 800<<20, 20<<30) // 4% of 20 GiB
	application.sampleCapacity(context.Background())
	if !application.lowDisk.Load() {
		t.Fatal("4% free did not raise the low-disk guard")
	}
	recorder := httptest.NewRecorder()
	application.metrics.handle(recorder, httptest.NewRequest("GET", "/metrics", nil))
	if !strings.Contains(recorder.Body.String(), "veritra_admission_low_disk 1\n") ||
		!strings.Contains(recorder.Body.String(), `veritra_admission_rejections_total{limit="deliveries"} 0`) {
		t.Fatalf("admission metrics missing:\n%s", recorder.Body.String())
	}
	assertClosedLabels(t, recorder.Body.String())
	withFilesystem(t, 1300<<20, 20<<30) // 6% of 20 GiB
	application.sampleCapacity(context.Background())
	if application.lowDisk.Load() {
		t.Fatal("6% free kept the low-disk guard")
	}
}

func TestDiskLowUsesTheSmallerOfFivePercentAndTwoGiB(t *testing.T) {
	for _, tc := range []struct {
		avail, size uint64
		low         bool
	}{
		{1 << 30, 40 << 30, true},    // 2.5% of the 40 GiB PVC
		{3 << 30, 40 << 30, false},   // 7.5%
		{12 << 30, 252 << 30, false}, // 4.8% of a large shared disk, still 12 GiB free
		{1 << 30, 252 << 30, true},   // under 2 GiB
		{0, 0, false},                // unknown size
	} {
		if got := diskLow(tc.avail, tc.size); got != tc.low {
			t.Fatalf("diskLow(%d MiB, %d MiB) = %v", tc.avail>>20, tc.size>>20, got)
		}
	}
}
