//go:build !unix && !windows

package app

// filesystemUsage is unknown on this platform; the filesystem gauges are
// then omitted and the platform's own disk monitoring applies.
func filesystemUsage(string) (avail, size uint64, ok bool) { return 0, 0, false }
