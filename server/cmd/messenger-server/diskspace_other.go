//go:build !unix

package main

// freeBytes is unknown on this platform; the preflight is skipped and a
// full disk is caught by the write itself, before anything live is touched.
func freeBytes(string) (uint64, bool) { return 0, false }
