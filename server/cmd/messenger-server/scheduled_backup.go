package main

// Scheduled backups (card I45, T45B). One run takes a backup, proves it with
// a disposable restore drill, copies it to the off-host directory, verifies
// the copy, and prunes old local backups. Only a run that passes all of that
// counts as a success in the status file the server reports from.
//
// The off-host destination is a directory that the host mounts (NFS, SMB,
// an rclone or restic mount, ...), so no storage credential passes through
// this process, its environment or its logs.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"private-messenger/server/internal/backupstatus"
	"private-messenger/server/internal/config"
)

const (
	backupNamePrefix  = "veritra-"
	defaultBackupKeep = 7
)

type scheduledBackupOptions struct {
	LocalDir   string
	OffsiteDir string
	Keep       int
	Now        func() time.Time
}

func scheduledBackupOptionsFromEnv(cfg config.Config) (scheduledBackupOptions, error) {
	options := scheduledBackupOptions{
		LocalDir:   filepath.Join(cfg.DataDir, "backups"),
		OffsiteDir: strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_BACKUP_OFFSITE_DIR")),
		Keep:       defaultBackupKeep,
		Now:        time.Now,
	}
	if value := strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_BACKUP_KEEP")); value != "" {
		keep, err := strconv.Atoi(value)
		if err != nil || keep < 1 || keep > 365 {
			return options, errors.New("PRIVATE_MESSENGER_BACKUP_KEEP must be between 1 and 365")
		}
		options.Keep = keep
	}
	return options, nil
}

func scheduledBackup(ctx context.Context, cfg config.Config, options scheduledBackupOptions, stdout io.Writer) error {
	fail := func(step string, err error) error {
		if recordErr := backupstatus.RecordFailure(cfg.DataDir, step, options.Now()); recordErr != nil {
			err = errors.Join(err, recordErr)
		}
		return fmt.Errorf("scheduled backup failed at %s: %w", step, err)
	}
	name := backupNamePrefix + options.Now().UTC().Format("20060102T150405Z")
	local := filepath.Join(options.LocalDir, name)
	if err := backup(ctx, cfg, []string{local}, io.Discard); err != nil {
		return fail(backupstatus.StepBackup, err)
	}
	if err := verifyBackup(ctx, []string{local}, io.Discard); err != nil {
		return fail(backupstatus.StepVerify, err)
	}
	if options.OffsiteDir != "" {
		if err := copyBackupOffsite(local, filepath.Join(options.OffsiteDir, name)); err != nil {
			return fail(backupstatus.StepOffsite, err)
		}
	}
	if err := pruneBackups(options.LocalDir, options.Keep); err != nil {
		return fail(backupstatus.StepPrune, err)
	}
	if options.OffsiteDir != "" {
		if err := pruneBackups(options.OffsiteDir, options.Keep); err != nil {
			return fail(backupstatus.StepPrune, err)
		}
	}
	if err := backupstatus.RecordSuccess(cfg.DataDir, options.Now()); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "scheduled backup verified: %s\n", name)
	return nil
}

// copyBackupOffsite copies a verified backup into a staging directory at the
// destination, checks every file against the manifest there, and only then
// publishes it under its final name.
func copyBackupOffsite(source, destination string) error {
	if _, err := os.Lstat(destination); err == nil {
		return errors.New("off-host backup already exists")
	} else if !os.IsNotExist(err) {
		return err
	}
	manifest, err := readAndValidateBackupManifest(source)
	if err != nil {
		return err
	}
	parent := filepath.Dir(destination)
	var need int64
	if info, err := os.Stat(filepath.Join(source, manifest.DatabaseFile)); err == nil {
		need = info.Size()
	}
	for _, blob := range manifest.Blobs {
		need += blob.SizeBytes
	}
	if err := os.MkdirAll(parent, 0o700); err != nil {
		return err
	}
	if err := requireFreeSpace(parent, need); err != nil {
		return err
	}
	stage, err := makeStagingDir(parent, ".veritra-offsite-")
	if err != nil {
		return err
	}
	defer removeStagingDir(stage)
	if err := os.Mkdir(filepath.Join(stage, "blobs"), 0o700); err != nil {
		return err
	}
	files := []string{manifest.DatabaseFile, "manifest.json"}
	for _, blob := range manifest.Blobs {
		files = append(files, filepath.Join("blobs", blob.StorageKey))
	}
	for _, file := range files {
		if err := faultHook("offsite:copy"); err != nil {
			return err
		}
		if err := copyFile(filepath.Join(source, file), filepath.Join(stage, file), 0o600); err != nil {
			return err
		}
	}
	sum, _, err := fileSHA256(filepath.Join(stage, manifest.DatabaseFile))
	if err != nil || !strings.EqualFold(sum, manifest.DatabaseSHA256) {
		return errors.New("off-host database copy failed verification")
	}
	for _, blob := range manifest.Blobs {
		sum, size, err := fileSHA256(filepath.Join(stage, "blobs", blob.StorageKey))
		if err != nil || size != blob.SizeBytes || !strings.EqualFold(sum, blob.SHA256) {
			return fmt.Errorf("off-host copy of blob %s failed verification", blob.StorageKey)
		}
	}
	if err := syncDir(filepath.Join(stage, "blobs")); err != nil {
		return err
	}
	if err := syncDir(stage); err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(stage, stagingMarkerName)); err != nil {
		return err
	}
	if err := os.Rename(stage, destination); err != nil {
		_ = os.WriteFile(filepath.Join(stage, stagingMarkerName), nil, 0o600)
		return err
	}
	return syncDir(parent)
}

// pruneBackups keeps the newest keep backups in dir. Only directories named
// like a scheduled backup that hold a valid manifest are candidates; nothing
// else in dir is ever removed.
func pruneBackups(dir string, keep int) error {
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var names []string
	for _, entry := range entries {
		name := entry.Name()
		if !entry.IsDir() || !strings.HasPrefix(name, backupNamePrefix) {
			continue
		}
		if _, err := time.Parse("20060102T150405Z", strings.TrimPrefix(name, backupNamePrefix)); err != nil {
			continue
		}
		if _, err := readAndValidateBackupManifest(filepath.Join(dir, name)); err != nil {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)
	for len(names) > keep {
		if err := os.RemoveAll(filepath.Join(dir, names[0])); err != nil {
			return err
		}
		names = names[1:]
	}
	return nil
}
