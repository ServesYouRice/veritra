//go:build unix

package main

import "golang.org/x/sys/unix"

// freeBytes reports the space available to this process on the file system
// that holds path.
func freeBytes(path string) (uint64, bool) {
	var stat unix.Statfs_t
	if err := unix.Statfs(path, &stat); err != nil {
		return 0, false
	}
	return uint64(stat.Bavail) * uint64(stat.Bsize), true
}
