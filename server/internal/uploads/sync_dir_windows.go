//go:build windows

package uploads

// syncDirectory is a no-op on Windows: a directory handle cannot be flushed
// (FlushFileBuffers needs write access), and NTFS journals the rename's
// metadata itself.
func syncDirectory(string) error {
	return nil
}
