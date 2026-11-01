//go:build windows

package app

import "golang.org/x/sys/windows"

// filesystemUsage reports the space available to this process and the total
// size of the volume that holds path.
func filesystemUsage(path string) (avail, size uint64, ok bool) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, 0, false
	}
	var free, total, totalFree uint64
	if err := windows.GetDiskFreeSpaceEx(p, &free, &total, &totalFree); err != nil {
		return 0, 0, false
	}
	return free, total, true
}
