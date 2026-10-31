//go:build windows

package config

import "os"

func openSecretFile(path string) (*os.File, error) {
	return os.Open(path)
}
