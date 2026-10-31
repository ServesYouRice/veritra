package app

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/config"
)

// Admission wiring (card I49, T49D): the instance storage default comes
// from the blob volume, the per-account write budget is built from the
// resolved limits, and the capacity sampler's disk reading drives the
// low-disk write guard.

// Writes stop when the database or blob file system has less free space
// than the smaller of 5% of its size and 2 GiB: a percentage alone would
// stop a large shared disk with plenty of room. VeritraDataDiskLow pages
// earlier, at 10%.
const (
	lowDiskFraction = 0.05
	lowDiskBytes    = 2 << 30
)

func diskLow(avail, size uint64) bool {
	return size > 0 && float64(avail) < min(lowDiskFraction*float64(size), lowDiskBytes)
}

// statFilesystem is filesystemUsage; tests replace it.
var statFilesystem = filesystemUsage

// ResolveInstanceStorage fills an unset instance storage limit from the size
// of the file system that holds the blobs and the scheduled-backup keep
// count. It returns the source for the startup log.
func ResolveInstanceStorage(cfg config.Config) (config.Config, string) {
	if cfg.Limits.InstanceStorageBytes != 0 {
		return cfg, "configured"
	}
	for _, path := range []string{cfg.StoragePath, cfg.DataDir, filepath.Dir(cfg.DataDir)} {
		if path == "" {
			continue
		}
		if _, size, ok := statFilesystem(path); ok && size > 0 {
			cfg.Limits.InstanceStorageBytes = config.DeriveInstanceStorage(int64(min(size, uint64(1<<62))), backupKeep())
			return cfg, "derived"
		}
	}
	return cfg, "default"
}

// backupKeep is PRIVATE_MESSENGER_BACKUP_KEEP as scheduled-backup reads it
// (7 when unset or invalid; the backup command itself rejects bad values).
func backupKeep() int {
	keep, err := strconv.Atoi(strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_BACKUP_KEEP")))
	if err != nil || keep < 1 || keep > 365 {
		return 7
	}
	return keep
}

func logLimits(logger *slog.Logger, limits config.Limits, source string) {
	logger.Info("admission_limits",
		"instance_storage_mib", limits.InstanceStorageBytes>>20,
		"instance_storage_source", source,
		"account_storage_mib", limits.AccountStorageBytes>>20,
		"account_blobs", limits.AccountBlobs,
		"devices_per_account", limits.DevicesPerAccount,
		"conversation_members", limits.ConversationMembers,
		"conversations_per_account", limits.ConversationsPerAccount,
		"key_package_claims_per_target", limits.KeyPackageClaimsPerTarget,
		"deliveries_per_minute", limits.DeliveriesPerMinute,
		"write_mib_per_hour", limits.WriteBytesPerHour>>20,
		"sockets_per_ipv6_prefix", limits.SocketsPerIPv6Prefix,
	)
}

func newBudget(limits config.Limits, counters *admission.Counters) *admission.Budget {
	return admission.NewBudget(limits.DeliveriesPerMinute, limits.WriteBytesPerHour, counters)
}

func writeAdmissionMetrics(w io.Writer, counters *admission.Counters, lowDisk bool) {
	_, _ = fmt.Fprint(w, "# TYPE veritra_admission_rejections_total counter\n")
	counters.Each(func(limit string, rejected int64) {
		_, _ = fmt.Fprintf(w, "veritra_admission_rejections_total{limit=%q} %d\n", limit, rejected)
	})
	guard := 0
	if lowDisk {
		guard = 1
	}
	_, _ = fmt.Fprint(w, "# TYPE veritra_admission_low_disk gauge\n")
	_, _ = fmt.Fprintf(w, "veritra_admission_low_disk %d\n", guard)
}
