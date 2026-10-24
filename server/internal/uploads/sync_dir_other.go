//go:build !windows

package uploads

import "os"

// syncDirectory makes a rename inside path durable.
func syncDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
