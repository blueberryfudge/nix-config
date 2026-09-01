package main

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"time"
)

func itoa(n int) string { return strconv.Itoa(n) }

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func nowUTC() string { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }

// corrID returns a correlation id (uuid-ish; a random hex token is plenty).
func corrID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(b)
}

var startupGateRe = regexp.MustCompile(`trust this folder|do you trust|yes, i trust|select .*login|sign ?in|log ?in|authenticat|onboard|api key`)

// resolvedExe returns this binary's fully symlink-resolved path. It is the
// daemon's VERSION STAMP: after a nix rebuild + home-manager switch the `cartel`
// symlink repoints into a new /nix/store path, so a fresh CLI's resolvedExe
// differs from a running daemon's - the trigger to replace it.
func resolvedExe() string {
	p, err := os.Executable()
	if err != nil {
		return ""
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}
