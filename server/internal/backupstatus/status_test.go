package backupstatus

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"testing"
	"time"
)

const (
	helperEnv      = "BACKUPSTATUS_TEST_HELPER_DIR"
	helperCountEnv = "BACKUPSTATUS_TEST_HELPER_COUNT"
)

// TestHelperProcess is the body of the separate processes the concurrency
// test starts; it does nothing in a normal run.
func TestHelperProcess(t *testing.T) {
	dir := os.Getenv(helperEnv)
	if dir == "" {
		t.Skip("helper process only")
	}
	count, err := strconv.Atoi(os.Getenv(helperCountEnv))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < count; i++ {
		if err := RecordFailure(dir, StepOffsite, time.Now()); err != nil {
			t.Fatalf("helper RecordFailure: %v", err)
		}
	}
}

func TestReadBeforeAnyRecord(t *testing.T) {
	if _, ok := Read(t.TempDir()); ok {
		t.Fatal("status reported for an empty directory")
	}
	if err := RecordSuccess("", time.Now()); err == nil {
		t.Fatal("RecordSuccess accepted an empty data directory")
	}
}

// Recorders overlap in one process and across processes (scheduled backup and
// verify-backup share a data directory). No update may be lost, no call may
// fail, and no temporary file may remain (VAL-210).
func TestConcurrentRecordersLoseNothing(t *testing.T) {
	dir := t.TempDir()
	const (
		goroutines = 6
		perWorker  = 25
		processes  = 2
		perProcess = 40
	)
	var helpers []*exec.Cmd
	for i := 0; i < processes; i++ {
		cmd := exec.Command(os.Args[0], "-test.run=^TestHelperProcess$")
		cmd.Env = append(os.Environ(), helperEnv+"="+dir, helperCountEnv+"="+strconv.Itoa(perProcess))
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		helpers = append(helpers, cmd)
	}

	var wg sync.WaitGroup
	errs := make(chan error, goroutines*perWorker*2)
	for g := 0; g < goroutines; g++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			for i := 0; i < perWorker; i++ {
				errs <- RecordFailure(dir, StepBackup, time.Now())
			}
		}()
		go func() {
			defer wg.Done()
			for i := 0; i < perWorker; i++ {
				errs <- RecordDrill(dir, true, time.Now())
			}
		}()
	}
	wg.Wait()
	for _, cmd := range helpers {
		if err := cmd.Wait(); err != nil {
			t.Fatalf("helper process failed: %v", err)
		}
	}
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("recorder failed: %v", err)
		}
	}

	status, ok := Read(dir)
	if !ok {
		t.Fatal("no readable status after concurrent writes")
	}
	if want := goroutines*perWorker + processes*perProcess; status.ConsecutiveFailures != want {
		t.Fatalf("consecutive failures = %d, want %d (lost updates)", status.ConsecutiveFailures, want)
	}
	if status.LastDrillAt == nil || !status.LastDrillPassed {
		t.Fatalf("drill result lost: %+v", status)
	}
	if status.LastFailureAt == nil {
		t.Fatalf("failure time lost: %+v", status)
	}
	if err := RecordSuccess(dir, time.Now()); err != nil {
		t.Fatal(err)
	}
	status, _ = Read(dir)
	if status.LastSuccessAt == nil || status.LastDrillAt == nil || status.ConsecutiveFailures != 0 {
		t.Fatalf("success did not keep the drill or reset failures: %+v", status)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		if name != fileName && name != lockFileName {
			t.Fatalf("unexpected file %q left in the data directory (all: %v)", name, names)
		}
	}
}

// A temporary file left by an older build does not break Read or the next
// write.
func TestLegacyTempFileIsHarmless(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, fileName+".tmp"), []byte("{broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := Read(dir); ok {
		t.Fatal("a temp file counted as a status")
	}
	if err := RecordSuccess(dir, time.Now()); err != nil {
		t.Fatal(err)
	}
	if status, ok := Read(dir); !ok || status.LastSuccessAt == nil {
		t.Fatalf("status after a leftover temp file: %+v ok=%v", status, ok)
	}
}

func TestStatusFileMode(t *testing.T) {
	dir := t.TempDir()
	if err := RecordDrill(dir, true, time.Now()); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dir, fileName))
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode&0o077 != 0 && os.PathSeparator == '/' {
		t.Fatalf("status file mode = %v, want owner-only", mode)
	}
}
