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
	// restoreDirLockName guards the journal of its directory (see
	// acquireRestoreDirLock). It does not match the staging prefix.
	restoreDirLockName = ".veritra-restore.lock"
	backupFormat       = "v1"
	// drillDirName is the restore drill's scratch area inside the data dir.
	// The data dir is always writable (the database lives there) and is
	// where a real restore stages, so the drill needs no /tmp (the image is
	// FROM scratch and may run with a read-only root filesystem). The name
	// is hidden and does not match backupNamePrefix, so pruning and backup
	// listings never treat it as a backup, and backup only copies the
	// database and referenced blobs, so the scratch is never backed up.
	drillDirName = ".veritra-restore-drill"
)

// faultHook lets tests stop an operation at a named step, as a crash, a full
// disk or a permission failure would.
var faultHook = func(step string) error { return nil }

// maxBackupManifestBytes caps a backup manifest. backup() refuses to publish
// a larger one and every reader rejects it, so a backup that is written can
// always be restored. One blob entry takes about 190 bytes (measured: 188
// with a blob_<32 hex> key and an 8-digit size), so 64 MiB holds roughly
// 350,000 attachments while reading one stays well within a small host's
// memory. Blob count has no other bound (T49D limits bytes, not files).
// A var so tests can lower it.
var maxBackupManifestBytes int64 = 64 << 20

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
	if err := writeStagingMarker(dir); err != nil {
		_ = os.Remove(dir)
		return "", err
	}
	return dir, nil
}

func writeStagingMarker(dir string) error {
	return os.WriteFile(filepath.Join(dir, stagingMarkerName), []byte(fmt.Sprintf("pid=%d\n", os.Getpid())), 0o600)
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
	if err := faultHook("sync:" + dir); err != nil {
		return err
	}
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
	// The trailing newline counts too.
	if size := int64(len(manifestBytes)) + 1; size > maxBackupManifestBytes {
		return fmt.Errorf("backup manifest of %d bytes exceeds the restorable limit of %d bytes", size, maxBackupManifestBytes)
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
	file, err := os.Open(filepath.Join(root, "manifest.json"))
	if err != nil {
		return instanceBackupManifest{}, err
	}
	defer file.Close()
	// One byte past the limit is enough to tell an oversized manifest.
	raw, err := io.ReadAll(io.LimitReader(file, maxBackupManifestBytes+1))
	if err != nil {
		return instanceBackupManifest{}, err
	}
	if int64(len(raw)) > maxBackupManifestBytes {
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
	// blobDir is a second staging directory beside the live blob directory,
	// used when its parent differs from the database's, so activating the
	// blobs is a rename within one file system. Empty otherwise.
	blobDir string
}

// remove deletes the staging directories (only those carrying the marker).
func (staged stagedRestore) remove() {
	_ = removeStagingDir(staged.dir)
	_ = removeStagingDir(staged.blobDir)
}

// stageBackup copies and verifies a backup into invocation-owned
// directories next to the live database and blob directory. Nothing live is
// touched.
func stageBackup(cfg config.Config, src, liveDatabase, liveBlobs string) (stagedRestore, error) {
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
	databaseNeed := sourceInfo.Size()
	var blobNeed int64
	if manifest != nil {
		for _, blob := range manifest.Blobs {
			blobNeed += blob.SizeBytes
		}
	}
	parent := filepath.Dir(liveDatabase)
	blobParent := filepath.Dir(liveBlobs)
	separateBlobs := manifest != nil && blobParent != parent
	if err := os.MkdirAll(parent, 0o700); err != nil {
		return stagedRestore{}, err
	}
	if separateBlobs {
		if err := os.MkdirAll(blobParent, 0o700); err != nil {
			return stagedRestore{}, err
		}
		if err := requireFreeSpace(parent, databaseNeed); err != nil {
			return stagedRestore{}, err
		}
		if err := requireFreeSpace(blobParent, blobNeed); err != nil {
			return stagedRestore{}, err
		}
	} else if err := requireFreeSpace(parent, databaseNeed+blobNeed); err != nil {
		return stagedRestore{}, err
	}
	dir, err := makeStagingDir(parent, ".veritra-restore-")
	if err != nil {
		return stagedRestore{}, err
	}
	staged := stagedRestore{dir: dir, database: filepath.Join(dir, "database.db")}
	fail := func(err error) (stagedRestore, error) {
		staged.remove()
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
	if separateBlobs {
		staged.blobDir, err = makeStagingDir(blobParent, ".veritra-restore-blobs-")
		if err != nil {
			return fail(err)
		}
		staged.blobs = filepath.Join(staged.blobDir, "blobs")
	}
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
	if staged.blobDir != "" {
		// The journal names this directory; the journal write syncs only
		// the database's parent.
		for _, synced := range []string{staged.blobDir, blobParent} {
			if err := syncDir(synced); err != nil {
				return fail(err)
			}
		}
	}
	if err := syncDir(dir); err != nil {
		return fail(err)
	}
	return staged, nil
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
	// BlobStagingDir is set (journal Version 2) when the blob directory's
	// parent differs from the database's: restored blobs are staged there,
	// so every blob rename stays on one file system.
	BlobStagingDir string `json:"blob_staging_dir,omitempty"`
}

func journalPath(liveDatabase string) string {
	return filepath.Join(filepath.Dir(liveDatabase), restoreJournalName)
}

// parents lists the directories whose entries a restore or its rollback
// renames: the database's parent and, when it differs, the blob directory's.
func (journal restoreJournal) parents() []string {
	parents := []string{filepath.Dir(journal.Database)}
	if journal.Blobs != "" && filepath.Dir(journal.Blobs) != parents[0] {
		parents = append(parents, filepath.Dir(journal.Blobs))
	}
	return parents
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
	// One restore at a time per database: a second one would share the
	// journal path and could roll back the first one mid-activation.
	lock, err := acquireRestoreLock(live)
	if err != nil {
		return err
	}
	defer lock.Release()
	// Another database in the same directory shares the journal path; its
	// restore must not have its journal overwritten or removed.
	dirLock, err := acquireRestoreDirLock(live)
	if err != nil {
		return err
	}
	defer dirLock.Release()
	// A running server holds its process locks even when idle, which the
	// SQLite probe below cannot see in WAL mode.
	server, err := acquireServerExclusion(cfg)
	if err != nil {
		return fmt.Errorf("a server appears to be running; stop the server before restore: %w", err)
	}
	defer server.Release()
	// A server of another database may share the blob directory; only its
	// blob-storage lock shows it. Released before activation renames the
	// directory that holds it (see blobStorageLock).
	blobLock, err := lockExistingBlobStorage(cfg)
	if err != nil {
		return fmt.Errorf("a server appears to be running; stop the server before restore: %w", err)
	}
	defer blobLock.Release()
	if _, err := os.Stat(journalPath(live)); err == nil {
		return errors.New("an earlier restore is unfinished; run the command again after it is settled")
	}
	staged, err := stageBackup(cfg, args[0], live, liveBlobs)
	if err != nil {
		return err
	}
	path := journalPath(live)
	// Recovery moves restored files back into staging before it puts an
	// original back, so staging goes only once no journal names it. A crash
	// leaves the journal, and so leaves staging as well.
	defer func() {
		if _, err := os.Lstat(path); os.IsNotExist(err) {
			staged.remove()
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
	if staged.blobDir != "" {
		// An older build cannot settle this journal; Version 2 makes it
		// refuse instead of rolling back without the blob staging.
		journal.Version = 2
		journal.BlobStagingDir = staged.blobDir
	}
	if err := blobLock.Release(); err != nil {
		return fmt.Errorf("release blob storage lock: %w", err)
	}
	if err := writeJournal(path, journal); err != nil {
		return fmt.Errorf("write restore journal: %w", err)
	}
	step := func(name string, action func() error) error {
		if err := faultHook(name); err != nil {
			return err
		}
		return action()
	}
	// Renames change the entries of the database's parent and, when it
	// differs, the blob directory's parent; both must be durable before the
	// journal may say "activated".
	syncParents := func() error {
		for _, parent := range journal.parents() {
			if err := syncDir(parent); err != nil {
				return err
			}
		}
		return nil
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
		if err := syncParents(); err != nil {
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
		if err := syncParents(); err != nil {
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
			return err
		}
		if rollbackErr := rollBackRestore(journal); rollbackErr != nil {
			return errors.Join(err, rollbackErr)
		}
		if os.Remove(path) == nil {
			_ = syncDir(filepath.Dir(live))
		}
		return err
	}
	journal.State = "activated"
	if err := step("restore:record-activated", func() error { return writeJournal(path, journal) }); err != nil {
		return fmt.Errorf("record finished restore: %w", err)
	}
	if err := step("restore:finish", func() error { return os.Remove(path) }); err != nil {
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

// rollBackRestore puts every preserved original back: the database, then
// its WAL and SHM, then the blobs, stopping at the first failure. Restored
// copies are moved into staging only where an original is waiting to replace
// them, or when they sit at the live path with no original to lose.
func rollBackRestore(journal restoreJournal) error {
	if err := ensureStagingDir(journal.StagingDir); err != nil {
		return err
	}
	// Version 1 journals staged blobs beside the database.
	blobStaging := journal.StagingDir
	if journal.BlobStagingDir != "" {
		if err := ensureStagingDir(journal.BlobStagingDir); err != nil {
			return err
		}
		blobStaging = journal.BlobStagingDir
	}
	// withdraw moves a restored copy out of its live path into staging,
	// rather than deleting it. An earlier, interrupted attempt may have
	// used the plain name already.
	withdraw := func(live, staging, name string) error {
		if _, err := os.Lstat(live); os.IsNotExist(err) {
			return nil
		} else if err != nil {
			return err
		}
		target := filepath.Join(staging, name)
		if _, err := os.Lstat(target); err == nil {
			target += "-" + randomSuffix()
		} else if !os.IsNotExist(err) {
			return err
		}
		return os.Rename(live, target)
	}
	putBack := func(live, rollback, staging string) error {
		if rollback == "" {
			return nil
		}
		if _, err := os.Lstat(rollback); os.IsNotExist(err) {
			return nil // never moved, or already back: the original is live
		} else if err != nil {
			return err
		}
		if err := withdraw(live, staging, "rolled-back-"+filepath.Base(live)); err != nil {
			return err
		}
		return os.Rename(rollback, live)
	}
	syncParents := func() error {
		var result error
		for _, parent := range journal.parents() {
			result = errors.Join(result, syncDir(parent))
		}
		return result
	}
	// settle runs one step and stops the rollback at its first failure.
	// Every step can run again: a retry finds the originals that are already
	// back and moves only what is left.
	settle := func(err error) error {
		if err != nil {
			return errors.Join(err, syncParents())
		}
		return nil
	}
	// The database comes first. Its WAL holds committed data and SQLite does
	// not check which database a WAL belongs to, so the original -wal and
	// -shm may only go back once the original database is live again.
	err := faultHook("restore:rollback-database")
	if err == nil {
		if journal.DatabaseRollback != "" {
			err = putBack(journal.Database, journal.DatabaseRollback, journal.StagingDir)
		} else {
			// There was no live database: a restored one is simply withdrawn.
			err = withdraw(journal.Database, journal.StagingDir, "rolled-back-database.db")
		}
	}
	if err := settle(err); err != nil {
		return err
	}
	for live, rollback := range journal.Companions {
		if err := settle(putBack(live, rollback, journal.StagingDir)); err != nil {
			return err
		}
	}
	if journal.Blobs != "" {
		if journal.BlobsRollback != "" {
			err = putBack(journal.Blobs, journal.BlobsRollback, blobStaging)
		} else {
			err = withdraw(journal.Blobs, blobStaging, "rolled-back-blobs")
		}
		if err := settle(err); err != nil {
			return err
		}
	}
	return syncParents()
}

// ensureStagingDir recreates a journal's staging directory when it is gone,
// so a rollback has somewhere to put the restored copies. Older builds could
// remove it while the journal stayed. The caller has checked the path
// against the live instance (journalMatches) or created it itself.
func ensureStagingDir(dir string) error {
	info, err := os.Lstat(dir)
	if os.IsNotExist(err) {
		if err := os.Mkdir(dir, 0o700); err != nil {
			return fmt.Errorf("recreate restore staging: %w", err)
		}
		return writeStagingMarker(dir)
	}
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("restore staging %s is not a directory", dir)
	}
	return nil
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
	// The lock is taken only when there is a journal, so a plain start
	// leaves no lock file behind.
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return fmt.Errorf("read restore journal: %w", err)
	}
	// The journal may belong to a restore that is still running; settling
	// it now would roll back live work.
	lock, err := acquireRestoreLock(live)
	if err != nil {
		return err
	}
	defer lock.Release()
	// The journal may also belong to a restore of another database in this
	// directory.
	dirLock, err := acquireRestoreDirLock(live)
	if err != nil {
		return err
	}
	defer dirLock.Release()
	// Settling moves live files, so it never runs beside a server. The blob
	// lock is only checked: the rollback may move the directory holding it.
	server, err := acquireServerExclusion(cfg)
	if err != nil {
		return fmt.Errorf("a server appears to be running; stop the server so the interrupted restore can be settled: %w", err)
	}
	defer server.Release()
	blobLock, err := lockExistingBlobStorage(cfg)
	if err != nil {
		return fmt.Errorf("a server appears to be running; stop the server so the interrupted restore can be settled: %w", err)
	}
	if err := blobLock.Release(); err != nil {
		return fmt.Errorf("release blob storage lock: %w", err)
	}
	if err := faultHook("recover:locked"); err != nil {
		return err
	}
	return settleRestoreJournal(cfg, live, path, stdout)
}

// settleRestoreJournal reads the journal while the caller holds the restore
// lock, so it acts on what the last restore wrote, never on an older copy.
func settleRestoreJournal(cfg config.Config, live, path string, stdout io.Writer) error {
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		// The restore that owned it finished before the lock was taken.
		return nil
	}
	if err != nil {
		return fmt.Errorf("read restore journal: %w", err)
	}
	var journal restoreJournal
	if err := json.Unmarshal(raw, &journal); err != nil || !knownJournalVersion(journal) {
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
	_ = removeStagingDir(journal.BlobStagingDir)
	return syncDir(filepath.Dir(live))
}

// requireSettledRestore fails when a restore journal is present. Writers
// call it once they hold their locks: recovery ran before that, and a
// restore killed in between leaves an instance nothing may open yet.
func requireSettledRestore(cfg config.Config) error {
	live, err := filepath.Abs(cfg.DatabasePath)
	if err != nil {
		return err
	}
	if _, err := os.Lstat(journalPath(live)); err == nil {
		return errors.New("an interrupted restore must be settled first; run the command again")
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("check for a restore journal: %w", err)
	}
	return nil
}

// knownJournalVersion accepts Version 1 (blobs staged beside the database)
// and Version 2 (which may name a separate blob staging directory).
func knownJournalVersion(journal restoreJournal) bool {
	switch journal.Version {
	case 1:
		return journal.BlobStagingDir == ""
	case 2:
		return true
	default:
		return false
	}
}

func journalMatches(journal restoreJournal, live, liveBlobs string) bool {
	rollback := func(path, base string) bool {
		return path == "" || contained(path, filepath.Dir(base), filepath.Base(base)+".pre-restore-")
	}
	if journal.Database != live || !rollback(journal.DatabaseRollback, live) {
		return false
	}
	for companion, path := range journal.Companions {
		if (companion != live+"-wal" && companion != live+"-shm") || !rollback(path, companion) {
			return false
		}
	}
	if journal.Blobs != "" && (journal.Blobs != liveBlobs || !rollback(journal.BlobsRollback, liveBlobs)) {
		return false
	}
	if journal.BlobStagingDir != "" &&
		(journal.Blobs == "" || !contained(journal.BlobStagingDir, filepath.Dir(liveBlobs), ".veritra-restore-blobs-")) {
		return false
	}
	return contained(journal.StagingDir, filepath.Dir(live), ".veritra-restore-")
}

// contained reports whether path names an entry directly in parent whose
// name starts with prefix. The path must already be clean, so it cannot
// leave parent through "..", a trailing separator or a subdirectory: the
// kernel resolves those against whatever the directories hold, while the
// check here only sees the text.
func contained(path, parent, prefix string) bool {
	return path != "" && filepath.Clean(path) == path && filepath.Dir(path) == parent &&
		strings.HasPrefix(filepath.Base(path), prefix)
}

// makeDrillDir creates an invocation-owned, marked scratch directory under
// <data dir>/.veritra-restore-drill. Concurrent drills get separate
// directories, and cleanup goes through removeStagingDir, which only deletes
// a directory that carries this invocation's staging marker.
func makeDrillDir(cfg config.Config) (string, error) {
	if strings.TrimSpace(cfg.DataDir) == "" {
		return "", errors.New("data directory is not configured")
	}
	dataDir, err := filepath.Abs(cfg.DataDir)
	if err != nil {
		return "", err
	}
	base := filepath.Join(dataDir, drillDirName)
	if info, err := os.Lstat(base); err == nil && !info.IsDir() {
		return "", fmt.Errorf("%s exists and is not a directory", base)
	} else if err != nil && !os.IsNotExist(err) {
		return "", err
	}
	return makeStagingDir(base, "drill-")
}

// verifyBackup is a disposable restore drill: the backup is restored into a
// throwaway directory, migrated and checked, and the directory removed. A
// backup counts as good only after this passes.
func verifyBackup(ctx context.Context, cfg config.Config, args []string, stdout io.Writer) error {
	if len(args) != 1 {
		return errors.New("verify-backup requires path to an instance backup")
	}
	scratch, err := makeDrillDir(cfg)
	if err != nil {
		return fmt.Errorf("restore drill scratch: %w", err)
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
