package main

// Instance backup and restore (card I45).
//
// Every staging directory belongs to one invocation (os.MkdirTemp) and
// carries a provenance marker; only a directory with that marker is ever
// removed recursively. Files and directories are fsynced before they are
// renamed into place. A restore writes a journal before it moves any live
// file, so a crash at any point leaves either the original instance or the
// restored one, and the next command settles which.

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/storage"
)

const (
	stagingMarkerName  = ".veritra-staging"
	restoreJournalName = ".veritra-restore-journal.json"
	backupFormat       = "v1"
)

// faultHook lets tests stop an operation at a named step, as a crash, a full
// disk or a permission failure would.
var faultHook = func(step string) error { return nil }

// errSimulatedCrash makes restore stop without any cleanup, like a killed
// process.
var errSimulatedCrash = errors.New("simulated crash")

type instanceBackupManifest struct {
	Version        string               `json:"version"`
	CreatedAt      time.Time            `json:"created_at"`
	ProducedBy     string               `json:"produced_by,omitempty"`
	InstanceName   string               `json:"instance_name"`
	DatabaseFile   string               `json:"database_file"`
	DatabaseSHA256 string               `json:"database_sha256"`
	Migrations     []string             `json:"migrations"`
	Blobs          []backupManifestBlob `json:"blobs"`
}

type backupManifestBlob struct {
	StorageKey string `json:"storage_key"`
	SHA256     string `json:"sha256"`
	SizeBytes  int64  `json:"size_bytes"`
}

// makeStagingDir creates an invocation-owned directory next to target and
// marks it, so cleanup never touches a path this invocation did not create.
func makeStagingDir(parent, prefix string) (string, error) {
	if err := os.MkdirAll(parent, 0o700); err != nil {
		return "", err
	}
	dir, err := os.MkdirTemp(parent, prefix)
	if err != nil {
		return "", err
	}
	marker := filepath.Join(dir, stagingMarkerName)
	if err := os.WriteFile(marker, []byte(fmt.Sprintf("pid=%d\n", os.Getpid())), 0o600); err != nil {
		_ = os.Remove(dir)
		return "", err
	}
	return dir, nil
}

// removeStagingDir removes dir only when it carries the staging marker.
func removeStagingDir(dir string) error {
	if dir == "" {
		return nil
	}
	info, err := os.Lstat(filepath.Join(dir, stagingMarkerName))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("refusing to clean %s: staging marker is not a file", dir)
	}
	return os.RemoveAll(dir)
}

func syncDir(dir string) error {
	handle, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer handle.Close()
	if err := handle.Sync(); err != nil && !errors.Is(err, os.ErrInvalid) {
		return err
	}
	return nil
}

func writeFileSynced(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	file, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return syncDir(filepath.Dir(path))
}

func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Sync(); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

func fileSHA256(path string) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, file)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(hash.Sum(nil)), size, nil
}

// requireFreeSpace fails before any write when the file system holding dir
// cannot take need bytes plus a margin.
func requireFreeSpace(dir string, need int64) error {
	free, known := freeBytes(dir)
	if !known || need <= 0 {
		return nil
	}
	margin := need/10 + 16<<20
	if free < uint64(need+margin) {
		return fmt.Errorf("not enough free disk space in %s: need about %d bytes, %d available", dir, need+margin, free)
	}
	return nil
}

func randomSuffix() string {
	var b [6]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b[:])
}

func backup(ctx context.Context, cfg config.Config, args []string, stdout io.Writer) error {
	out := filepath.Join(cfg.DataDir, "backups", "veritra-"+time.Now().UTC().Format("20060102T150405Z"))
	if len(args) > 0 {
		out = args[0]
	}
	out, err := filepath.Abs(out)
	if err != nil {
		return err
	}
	if _, err := os.Lstat(out); err == nil {
		return errors.New("backup destination already exists")
	} else if !os.IsNotExist(err) {
		return err
	}
	parent := filepath.Dir(out)
	if info, err := os.Stat(cfg.DatabasePath); err == nil {
		if err := os.MkdirAll(parent, 0o700); err != nil {
			return err
		}
		if err := requireFreeSpace(parent, info.Size()); err != nil {
			return err
		}
	}
	stage, err := makeStagingDir(parent, ".veritra-backup-")
	if err != nil {
		return err
	}
	defer removeStagingDir(stage)
	if err := os.Mkdir(filepath.Join(stage, "blobs"), 0o700); err != nil {
		return err
	}
	store, err := storage.Open(ctx, cfg)
	if err != nil {
		return err
	}
	defer store.Close()
	databasePath := filepath.Join(stage, "database.db")
	if err := faultHook("backup:database"); err != nil {
		return err
	}
	if err := store.BackupTo(ctx, databasePath); err != nil {
		return err
	}
	if err := os.Chmod(databasePath, 0o600); err != nil {
		return err
	}
	if err := syncFile(databasePath); err != nil {
		return err
	}
	references, migrations, err := storage.ListDatabaseBlobReferences(ctx, databasePath)
	if err != nil {
		return err
	}
	var blobBytes int64
	for _, reference := range references {
		blobBytes += reference.SizeBytes
	}
	if err := requireFreeSpace(parent, blobBytes); err != nil {
		return err
	}
	manifest := instanceBackupManifest{
		Version: backupFormat, CreatedAt: time.Now().UTC(), ProducedBy: "veritra-server " + version,
		DatabaseFile: "database.db", Migrations: migrations, InstanceName: cfg.InstanceName,
	}
	manifest.DatabaseSHA256, _, err = fileSHA256(databasePath)
	if err != nil {
		return err
	}
	for _, reference := range references {
		key := filepath.Base(reference.StorageKey)
		if key != reference.StorageKey || key == "." || key == ".." {
			return fmt.Errorf("encrypted blob %s has an invalid storage key", reference.StorageKey)
		}
		if err := faultHook("backup:blob"); err != nil {
			return err
		}
		destination := filepath.Join(stage, "blobs", key)
		if err := copyFile(filepath.Join(cfg.StoragePath, key), destination, 0o600); err != nil {
			return fmt.Errorf("copy encrypted blob %s: %w", reference.StorageKey, err)
		}
		actualSHA, actualSize, err := fileSHA256(destination)
		if err != nil {
			return err
		}
		if actualSize != reference.SizeBytes || (reference.SHA256 != "" && !strings.EqualFold(actualSHA, reference.SHA256)) {
			return fmt.Errorf("encrypted blob %s failed size/checksum verification", reference.StorageKey)
		}
		manifest.Blobs = append(manifest.Blobs, backupManifestBlob{StorageKey: key, SHA256: actualSHA, SizeBytes: actualSize})
	}
	if err := syncDir(filepath.Join(stage, "blobs")); err != nil {
		return err
	}
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	if err := writeFileSynced(filepath.Join(stage, "manifest.json"), append(manifestBytes, '\n'), 0o600); err != nil {
		return err
	}
	if err := faultHook("backup:publish"); err != nil {
		return err
	}
	// The marker leaves before the directory is published, so the backup
	// itself can never be mistaken for a staging directory.
	if err := os.Remove(filepath.Join(stage, stagingMarkerName)); err != nil {
		return err
	}
	if err := os.Rename(stage, out); err != nil {
		_ = os.WriteFile(filepath.Join(stage, stagingMarkerName), nil, 0o600)
		return err
	}
	if err := syncDir(parent); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "instance backup written: %s\n", out)
	return nil
}

func syncFile(path string) error {
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}

func readAndValidateBackupManifest(root string) (instanceBackupManifest, error) {
	raw, err := os.ReadFile(filepath.Join(root, "manifest.json"))
	if err != nil {
		return instanceBackupManifest{}, err
	}
	if len(raw) > 1<<20 {
		return instanceBackupManifest{}, errors.New("backup manifest is too large")
	}
	var manifest instanceBackupManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return instanceBackupManifest{}, fmt.Errorf("invalid backup manifest: %w", err)
	}
	if manifest.Version != backupFormat || manifest.DatabaseFile != filepath.Base(manifest.DatabaseFile) ||
		manifest.DatabaseFile == "" || manifest.DatabaseFile == "." || manifest.DatabaseFile == ".." ||
		len(manifest.DatabaseSHA256) != 64 {
		return instanceBackupManifest{}, errors.New("unsupported or invalid backup manifest")
	}
	return manifest, nil
}

// stagedRestore is a verified copy of a backup, ready to be moved into place.
type stagedRestore struct {
	dir      string
	database string
	blobs    string // empty for a legacy database-only restore
}

// stageBackup copies and verifies a backup into an invocation-owned
// directory next to the live database. Nothing live is touched.
func stageBackup(cfg config.Config, src, liveDatabase string) (stagedRestore, error) {
	info, err := os.Stat(src)
	if err != nil {
		return stagedRestore{}, fmt.Errorf("backup not readable: %w", err)
	}
	var manifest *instanceBackupManifest
	root := src
	databaseSource := src
	if info.IsDir() {
		loaded, err := readAndValidateBackupManifest(src)
		if err != nil {
			return stagedRestore{}, err
		}
		manifest = &loaded
		databaseSource = filepath.Join(src, loaded.DatabaseFile)
	}
	sourceAbs, err := filepath.Abs(databaseSource)
	if err != nil {
		return stagedRestore{}, err
	}
	if sourceAbs == liveDatabase {
		return stagedRestore{}, errors.New("backup path must differ from the live database")
	}
	sourceInfo, err := os.Stat(sourceAbs)
	if err != nil {
		return stagedRestore{}, fmt.Errorf("backup not readable: %w", err)
	}
	need := sourceInfo.Size()
	if manifest != nil {
		for _, blob := range manifest.Blobs {
			need += blob.SizeBytes
		}
	}
	parent := filepath.Dir(liveDatabase)
	if err := os.MkdirAll(parent, 0o700); err != nil {
		return stagedRestore{}, err
	}
	if err := requireFreeSpace(parent, need); err != nil {
		return stagedRestore{}, err
	}
	dir, err := makeStagingDir(parent, ".veritra-restore-")
	if err != nil {
		return stagedRestore{}, err
	}
	staged := stagedRestore{dir: dir, database: filepath.Join(dir, "database.db")}
	fail := func(err error) (stagedRestore, error) {
		_ = removeStagingDir(dir)
		return stagedRestore{}, err
	}
	if err := faultHook("restore:stage-database"); err != nil {
		return fail(err)
	}
	if err := copyFile(sourceAbs, staged.database, 0o600); err != nil {
		return fail(fmt.Errorf("stage backup: %w", err))
	}
	if err := storage.ValidateDatabaseFile(context.Background(), staged.database); err != nil {
		return fail(fmt.Errorf("backup validation failed: %w", err))
	}
	if manifest == nil {
		return staged, nil
	}
	databaseSHA, _, err := fileSHA256(staged.database)
	if err != nil || !strings.EqualFold(databaseSHA, manifest.DatabaseSHA256) {
		return fail(errors.New("backup database checksum mismatch"))
	}
	references, migrations, err := storage.ListDatabaseBlobReferences(context.Background(), staged.database)
	if err != nil {
		return fail(err)
	}
	if strings.Join(migrations, "\x00") != strings.Join(manifest.Migrations, "\x00") || len(references) != len(manifest.Blobs) {
		return fail(errors.New("backup manifest does not match database contents"))
	}
	staged.blobs = filepath.Join(dir, "blobs")
	if err := os.Mkdir(staged.blobs, 0o700); err != nil {
		return fail(err)
	}
	manifestByKey := make(map[string]backupManifestBlob, len(manifest.Blobs))
	for _, blob := range manifest.Blobs {
		if blob.StorageKey == "" || filepath.Base(blob.StorageKey) != blob.StorageKey ||
			blob.StorageKey == "." || blob.StorageKey == ".." {
			return fail(errors.New("backup manifest contains an invalid blob key"))
		}
		manifestByKey[blob.StorageKey] = blob
	}
	for _, reference := range references {
		blob, ok := manifestByKey[reference.StorageKey]
		if !ok || blob.SizeBytes != reference.SizeBytes || (reference.SHA256 != "" && !strings.EqualFold(blob.SHA256, reference.SHA256)) {
			return fail(fmt.Errorf("backup manifest missing or mismatches blob %s", reference.StorageKey))
		}
		if err := faultHook("restore:stage-blob"); err != nil {
			return fail(err)
		}
		destination := filepath.Join(staged.blobs, blob.StorageKey)
		if err := copyFile(filepath.Join(root, "blobs", blob.StorageKey), destination, 0o600); err != nil {
			return fail(fmt.Errorf("stage encrypted blob %s: %w", blob.StorageKey, err))
		}
		sha, size, err := fileSHA256(destination)
		if err != nil || size != blob.SizeBytes || !strings.EqualFold(sha, blob.SHA256) {
			return fail(fmt.Errorf("backup blob %s failed checksum verification", blob.StorageKey))
		}
	}
	if err := syncDir(staged.blobs); err != nil {
		return fail(err)
	}
	return staged, syncDir(dir)
}

// restoreJournal records a restore in progress. Paths are checked against
// the live paths when the journal is read, so a damaged journal cannot
// direct a cleanup elsewhere.
type restoreJournal struct {
	Version          int               `json:"version"`
	State            string            `json:"state"` // activating, activated
	StartedAt        time.Time         `json:"started_at"`
	Database         string            `json:"database"`
	DatabaseRollback string            `json:"database_rollback,omitempty"`
	Companions       map[string]string `json:"companions,omitempty"` // live path -> rollback path
	Blobs            string            `json:"blobs,omitempty"`
	BlobsRollback    string            `json:"blobs_rollback,omitempty"`
	StagingDir       string            `json:"staging_dir"`
}

func journalPath(liveDatabase string) string {
	return filepath.Join(filepath.Dir(liveDatabase), restoreJournalName)
}

func writeJournal(path string, journal restoreJournal) error {
	data, err := json.MarshalIndent(journal, "", "  ")
	if err != nil {
		return err
	}
	_ = os.Remove(path + ".tmp")
	return writeFileSynced(path, data, 0o600)
}

func restore(cfg config.Config, args []string, stdout io.Writer) error {
	if len(args) != 1 {
		return errors.New("restore requires path to an instance backup")
	}
	live, err := filepath.Abs(cfg.DatabasePath)
	if err != nil {
		return err
	}
	liveBlobs, err := filepath.Abs(cfg.StoragePath)
	if err != nil {
		return err
	}
	if _, err := os.Stat(journalPath(live)); err == nil {
		return errors.New("an earlier restore is unfinished; run the command again after it is settled")
	}
	staged, err := stageBackup(cfg, args[0], live)
	if err != nil {
		return err
	}
	crashed := false
	defer func() {
		if !crashed {
			_ = removeStagingDir(staged.dir)
		}
	}()
	if _, err := os.Stat(live); err == nil {
		probeCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		err := storage.ProbeDatabaseExclusive(probeCtx, live)
		cancel()
		if err != nil {
			return fmt.Errorf("database appears in use; stop the server before restore: %w", err)
		}
	} else if !os.IsNotExist(err) {
		return err
	}

	suffix := ".pre-restore-" + time.Now().UTC().Format("20060102T150405Z") + "-" + randomSuffix()
	journal := restoreJournal{
		Version: 1, State: "activating", StartedAt: time.Now().UTC(), Database: live,
		Companions: map[string]string{}, StagingDir: staged.dir,
	}
	if _, err := os.Stat(live); err == nil {
		journal.DatabaseRollback = live + suffix
	}
	for _, companion := range []string{live + "-wal", live + "-shm"} {
		if _, err := os.Stat(companion); err == nil {
			// The WAL holds committed data: it moves with its database.
			journal.Companions[companion] = companion + suffix
		}
	}
	if staged.blobs != "" {
		journal.Blobs = liveBlobs
		if _, err := os.Stat(liveBlobs); err == nil {
			journal.BlobsRollback = liveBlobs + suffix
		}
	}
	path := journalPath(live)
	if err := writeJournal(path, journal); err != nil {
		return fmt.Errorf("write restore journal: %w", err)
	}
	step := func(name string, action func() error) error {
		if err := faultHook(name); err != nil {
			return err
		}
		return action()
	}
	activate := func() error {
		if journal.DatabaseRollback != "" {
			if err := step("restore:preserve-database", func() error { return os.Rename(live, journal.DatabaseRollback) }); err != nil {
				return fmt.Errorf("preserve live database: %w", err)
			}
		}
		for companion, rollback := range journal.Companions {
			if err := step("restore:preserve-companion", func() error { return os.Rename(companion, rollback) }); err != nil {
				return fmt.Errorf("preserve SQLite companion: %w", err)
			}
		}
		if journal.BlobsRollback != "" {
			if err := step("restore:preserve-blobs", func() error { return os.Rename(liveBlobs, journal.BlobsRollback) }); err != nil {
				return fmt.Errorf("preserve live blob directory: %w", err)
			}
		}
		if err := syncDir(filepath.Dir(live)); err != nil {
			return err
		}
		if err := step("restore:activate-database", func() error { return os.Rename(staged.database, live) }); err != nil {
			return fmt.Errorf("activate staged backup: %w", err)
		}
		if staged.blobs != "" {
			if err := step("restore:activate-blobs", func() error { return os.Rename(staged.blobs, liveBlobs) }); err != nil {
				return fmt.Errorf("activate staged blob directory: %w", err)
			}
		}
		if err := syncDir(filepath.Dir(live)); err != nil {
			return err
		}
		if err := step("restore:validate", func() error {
			return storage.ValidateDatabaseFile(context.Background(), live)
		}); err != nil {
			return fmt.Errorf("restored database validation failed: %w", err)
		}
		return nil
	}
	if err := activate(); err != nil {
		if errors.Is(err, errSimulatedCrash) {
			crashed = true
			return err
		}
		if rollbackErr := rollBackRestore(journal); rollbackErr != nil {
			return errors.Join(err, rollbackErr)
		}
		_ = os.Remove(path)
		return err
	}
	journal.State = "activated"
	if err := writeJournal(path, journal); err != nil {
		return fmt.Errorf("record finished restore: %w", err)
	}
	if err := step("restore:finish", func() error { return os.Remove(path) }); err != nil {
		if errors.Is(err, errSimulatedCrash) {
			crashed = true
		}
		return err
	}
	_ = syncDir(filepath.Dir(live))
	fmt.Fprintf(stdout, "database restored to: %s\n", cfg.DatabasePath)
	if journal.DatabaseRollback != "" {
		fmt.Fprintf(stdout, "previous database preserved for rollback: %s\n", journal.DatabaseRollback)
	}
	if staged.blobs == "" {
		fmt.Fprintln(stdout, "warning: legacy database-only restore does not include encrypted blobs")
	} else if journal.BlobsRollback != "" {
		fmt.Fprintf(stdout, "previous blob directory preserved for rollback: %s\n", journal.BlobsRollback)
	}
	return nil
}

// rollBackRestore puts every preserved original back. Restored copies are
// removed only where an original is waiting to replace them, or when they
// sit at the live path with no original to lose.
func rollBackRestore(journal restoreJournal) error {
	var result error
	putBack := func(live, rollback string, directory bool) {
		if rollback == "" {
			return
		}
		if _, err := os.Lstat(rollback); err != nil {
			if !os.IsNotExist(err) {
				result = errors.Join(result, err)
			}
			return // never moved: the original is still live
		}
		if _, err := os.Lstat(live); err == nil {
			// The restored copy came from the staging directory; move it back
			// there rather than deleting it.
			if err := os.Rename(live, filepath.Join(journal.StagingDir, "rolled-back-"+filepath.Base(live))); err != nil {
				result = errors.Join(result, err)
				return
			}
		}
		if err := os.Rename(rollback, live); err != nil {
			result = errors.Join(result, err)
		}
	}
	putBack(journal.Database, journal.DatabaseRollback, false)
	for live, rollback := range journal.Companions {
		putBack(live, rollback, false)
	}
	if journal.DatabaseRollback == "" {
		// There was no live database: a restored one is simply withdrawn.
		if _, err := os.Lstat(journal.Database); err == nil {
			result = errors.Join(result, os.Rename(journal.Database,
				filepath.Join(journal.StagingDir, "rolled-back-database.db")))
		}
	}
	if journal.Blobs != "" {
		putBack(journal.Blobs, journal.BlobsRollback, true)
		if journal.BlobsRollback == "" {
			if _, err := os.Lstat(journal.Blobs); err == nil {
				result = errors.Join(result, os.Rename(journal.Blobs,
					filepath.Join(journal.StagingDir, "rolled-back-blobs")))
			}
		}
	}
	if err := syncDir(filepath.Dir(journal.Database)); err != nil {
		result = errors.Join(result, err)
	}
	return result
}

// recoverInterruptedRestore settles a restore that a crash cut short: an
// unfinished activation is rolled back to the original instance, a finished
// one is kept. It runs before any command opens the database.
func recoverInterruptedRestore(cfg config.Config, stdout io.Writer) error {
	live, err := filepath.Abs(cfg.DatabasePath)
	if err != nil {
		return err
	}
	path := journalPath(live)
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read restore journal: %w", err)
	}
	var journal restoreJournal
	if err := json.Unmarshal(raw, &journal); err != nil || journal.Version != 1 {
		return fmt.Errorf("restore journal %s is damaged; resolve it by hand before starting", path)
	}
	liveBlobs, err := filepath.Abs(cfg.StoragePath)
	if err != nil {
		return err
	}
	if !journalMatches(journal, live, liveBlobs) {
		return fmt.Errorf("restore journal %s does not match this instance; resolve it by hand", path)
	}
	switch journal.State {
	case "activated":
		fmt.Fprintln(stdout, "an interrupted restore had finished; keeping the restored instance")
	case "activating":
		if err := rollBackRestore(journal); err != nil {
			return fmt.Errorf("roll back interrupted restore: %w", err)
		}
		fmt.Fprintln(stdout, "an interrupted restore was rolled back; the previous instance is back in place")
	default:
		return fmt.Errorf("restore journal %s has an unknown state", path)
	}
	if err := os.Remove(path); err != nil {
		return err
	}
	_ = removeStagingDir(journal.StagingDir)
	return syncDir(filepath.Dir(live))
}

func journalMatches(journal restoreJournal, live, liveBlobs string) bool {
	within := func(path, base string) bool {
		return path == "" || strings.HasPrefix(path, base+".pre-restore-")
	}
	if journal.Database != live || !within(journal.DatabaseRollback, live) {
		return false
	}
	for companion, rollback := range journal.Companions {
		if (companion != live+"-wal" && companion != live+"-shm") || !within(rollback, companion) {
			return false
		}
	}
	if journal.Blobs != "" && (journal.Blobs != liveBlobs || !within(journal.BlobsRollback, liveBlobs)) {
		return false
	}
	staging := filepath.Dir(journal.StagingDir) == filepath.Dir(live) &&
		strings.HasPrefix(filepath.Base(journal.StagingDir), ".veritra-restore-")
	return staging
}

// verifyBackup is a disposable restore drill: the backup is restored into a
// throwaway directory, migrated and checked, and the directory removed. A
// backup counts as good only after this passes.
func verifyBackup(ctx context.Context, args []string, stdout io.Writer) error {
	if len(args) != 1 {
		return errors.New("verify-backup requires path to an instance backup")
	}
	scratch, err := makeStagingDir(os.TempDir(), "veritra-restore-drill-")
	if err != nil {
		return err
	}
	defer removeStagingDir(scratch)
	drill := config.Config{
		DataDir:      scratch,
		DatabasePath: filepath.Join(scratch, "drill.db"),
		StoragePath:  filepath.Join(scratch, "blobs"),
		InstanceName: "restore drill",
		Environment:  "development",
	}
	if err := restore(drill, args, io.Discard); err != nil {
		return fmt.Errorf("restore drill failed: %w", err)
	}
	if err := migrate(ctx, drill, io.Discard); err != nil {
		return fmt.Errorf("restore drill failed: %w", err)
	}
	var report strings.Builder
	if err := doctor(ctx, drill, &report); err != nil {
		return fmt.Errorf("restore drill failed: %w", err)
	}
	fmt.Fprintf(stdout, "backup verified by a disposable restore: %s\n", args[0])
	return nil
}
