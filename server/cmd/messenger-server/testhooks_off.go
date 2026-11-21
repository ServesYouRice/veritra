//go:build !veritra_testhooks

package main

import (
	"context"
	"io"

	"private-messenger/server/internal/config"
)

// testHooksCompiled is false in every build without the veritra_testhooks
// tag, which includes every release build: the hooks in testhooks.go are
// not in the binary at all, so no flag or environment can turn them on.
const testHooksCompiled = false

func requireTestHookEnvironment(config.Config) error { return nil }

func runTestHook(context.Context, config.Config, string, []string, io.Writer) (bool, error) {
	return false, nil
}
