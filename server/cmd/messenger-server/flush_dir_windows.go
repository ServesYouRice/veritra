//go:build windows

package main

// flushDir is a no-op on Windows: a directory handle cannot be flushed
// (FlushFileBuffers needs write access), and NTFS journals the rename's
// metadata itself.
func flushDir(string) error {
	return nil
}
