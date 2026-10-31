//go:build windows

package backupstatus

import (
	"os"

	"golang.org/x/sys/windows"
)

// lockFile blocks until it holds an exclusive lock on file. The recorders
// hold it for one small read-modify-write.
func lockFile(file *os.File) error {
	var overlapped windows.Overlapped
	return windows.LockFileEx(
		windows.Handle(file.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK,
		0,
		1,
		0,
		&overlapped,
	)
}

func unlockFile(file *os.File) error {
	var overlapped windows.Overlapped
	return windows.UnlockFileEx(windows.Handle(file.Fd()), 0, 1, 0, &overlapped)
}

// syncDirectory is a no-op on Windows: a directory handle cannot be flushed
// (FlushFileBuffers needs write access), and NTFS journals the rename's
// metadata itself.
func syncDirectory(string) error {
	return nil
}
