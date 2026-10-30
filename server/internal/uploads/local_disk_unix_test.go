//go:build linux || darwin || freebsd || openbsd || netbsd || dragonfly

package uploads

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// Disk use: allocated bytes per blob for small ciphertexts in the flat
// layout (filesystem block rounding), reported per blob.
func BenchmarkDiskUse(b *testing.B) {
	for _, size := range []int64{1, kib, 4*kib + 1, 64 * kib} {
		b.Run(fmt.Sprintf("%dB", size), func(b *testing.B) {
			store := newBenchLocalStore(b)
			keys := make([]string, 0, 256)
			for b.Loop() {
				ref := putBenchBlob(b, store, size)
				if len(keys) < cap(keys) {
					keys = append(keys, ref.StorageKey)
				}
			}
			var allocated int64
			for _, key := range keys {
				info, err := os.Stat(filepath.Join(store.root, key))
				if err != nil {
					b.Fatal(err)
				}
				if st, ok := info.Sys().(*syscall.Stat_t); ok {
					allocated += st.Blocks * 512
				}
			}
			if len(keys) > 0 {
				b.ReportMetric(float64(allocated)/float64(len(keys)), "disk_bytes/blob")
				b.ReportMetric(float64(allocated)/float64(int64(len(keys))*size), "disk/logical")
			}
		})
	}
}
