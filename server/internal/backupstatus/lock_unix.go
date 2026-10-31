//go:build !windows

package backupstatus

import (
	"os"

	"golang.org/x/sys/unix"
)

// lockFile blocks until it holds an exclusive advisory lock on file. The
// recorders hold it for one small read-modify-write.
func lockFile(file *os.File) error {
	for {
		err := unix.Flock(int(file.Fd()), unix.LOCK_EX)
		if err != unix.EINTR {
			return err
		}
	}
}

func unlockFile(file *os.File) error {
	return unix.Flock(int(file.Fd()), unix.LOCK_UN)
}

// syncDirectory makes a rename inside path durable.
func syncDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
