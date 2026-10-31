package storage

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestProbeDatabaseExclusiveDoesNotCreateAMissingDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.db")
	if err := ProbeDatabaseExclusive(context.Background(), path); err == nil {
		t.Fatal("probing a path with no database succeeded")
	}
	for _, name := range []string{path, path + "-wal", path + "-shm"} {
		if _, err := os.Stat(name); !os.IsNotExist(err) {
			t.Fatalf("the probe left %s behind (stat err = %v)", name, err)
		}
	}
}

func TestProbeDatabaseExclusiveStillRejectsAnActiveWriterAndAcceptsAQuietDatabase(t *testing.T) {
	ctx := context.Background()
	store, cfg := newTestStore(t, ctx)
	defer store.Close()
	if err := ProbeDatabaseExclusive(ctx, cfg.DatabasePath); err != nil {
		t.Fatalf("probe of a quiet database: %v", err)
	}
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `UPDATE instances SET name = name`); err != nil {
		t.Fatal(err)
	}
	if err := ProbeDatabaseExclusive(ctx, cfg.DatabasePath); err == nil {
		t.Fatal("probe passed while a writer held the database")
	}
}
