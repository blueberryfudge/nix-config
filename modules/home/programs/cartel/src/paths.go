package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// Runtime layout. Everything cartel owns lives under $CARTEL_HOME (~/cartel by
// default): state, the report/daemon sockets, worktrees, and the patrón run dir.
// Nothing is ever written into the directory cartel is invoked from.
var (
	cartelHome  = resolveHome()
	stateDir    = filepath.Join(cartelHome, "state")
	replyDir    = filepath.Join(stateDir, "replies")
	lockDir     = filepath.Join(cartelHome, ".lock.d")
	daemonSock  = filepath.Join(stateDir, "daemon.sock")
	daemonLog   = filepath.Join(stateDir, "daemon.log")
	daemonPidF  = filepath.Join(stateDir, "daemon.pid")
	watchLog    = filepath.Join(stateDir, "watch.log")
	eventsLog   = filepath.Join(stateDir, "events.log")
	patronRun   = filepath.Join(cartelHome, ".patron-run")
	worktreeDir = filepath.Join(cartelHome, "worktrees")
	reportsDir  = filepath.Join(cartelHome, "reports")
)

func resolveHome() string {
	if h := os.Getenv("CARTEL_HOME"); h != "" {
		return h
	}
	h, err := os.UserHomeDir()
	if err != nil || h == "" {
		h = os.Getenv("HOME")
	}
	return filepath.Join(h, "cartel")
}

// ensureDirs creates the owner-only state dirs. They feed the patrón's TRUSTED
// report channel, so they must not be a world-writable injection surface.
func ensureDirs() {
	_ = os.MkdirAll(stateDir, 0o700)
	_ = os.MkdirAll(replyDir, 0o700)
	_ = os.MkdirAll(reportsDir, 0o700)
	_ = os.Chmod(stateDir, 0o700)
	_ = os.Chmod(replyDir, 0o700)
	_ = os.Chmod(reportsDir, 0o700)
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "cartel: "+format+"\n", args...)
	os.Exit(1)
}

func stateFile(id string) string { return filepath.Join(stateDir, id+".json") }
func replyFile(id string) string { return filepath.Join(replyDir, id+".json") }

// reportFile is a sicario's deliverable document (the firstmate "scout-report"
// pattern): the FULL result of a task is written HERE by the sicario, never
// streamed as a long chat answer. Long TUI answers get visually duplicated in
// scrollback whenever the pane re-renders mid-stream (peek/resize), so the pane
// is never the artifact - this file is. It survives bury on purpose.
func reportFile(id string) string { return filepath.Join(reportsDir, id+".md") }

// valid_id: a short, lowercase, filesystem- and shell-safe handle. This is the
// ONLY thing allowed into the patrón's trusted report line, so keep it strict.
var idRe = regexp.MustCompile(`^[a-z][a-z0-9_-]*$`)

func validID(id string) bool { return len(id) <= 32 && idRe.MatchString(id) }

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
