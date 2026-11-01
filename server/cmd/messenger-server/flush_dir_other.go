//go:build !windows

package main

import (
	"errors"
	"os"
)

// flushDir fsyncs a directory so renames inside it are durable.
func flushDir(dir string) error {
	handle, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer handle.Close()
	if err := handle.Sync(); err != nil && !errors.Is(err, os.ErrInvalid) {
		return err
	}
	return nil
}
