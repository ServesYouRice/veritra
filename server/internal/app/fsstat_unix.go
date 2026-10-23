//go:build unix

package app

import "golang.org/x/sys/unix"

// filesystemUsage reports the space available to this process and the total
// size of the file system that holds path.
func filesystemUsage(path string) (avail, size uint64, ok bool) {
	var stat unix.Statfs_t
	if err := unix.Statfs(path, &stat); err != nil {
		return 0, 0, false
	}
	return uint64(stat.Bavail) * uint64(stat.Bsize), uint64(stat.Blocks) * uint64(stat.Bsize), true
}
