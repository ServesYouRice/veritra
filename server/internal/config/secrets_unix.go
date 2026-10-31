//go:build !windows

package config

import (
	"os"
	"syscall"
)

// openSecretFile opens path read-only without waiting for a writer, so a FIFO
// swapped in after the caller's stat cannot block startup. The flag changes
// nothing for regular files.
func openSecretFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
}
