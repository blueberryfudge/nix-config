package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// The cartel daemon is a single, on-demand, self-spawned watcher that replaces
// the old per-pane background `cartel lookout` processes. It owns the herdr event
// subscription, tracks every registered patrón pane, and delivers ONE coalesced,
// composer-safe `[cartel] settled: <ids>` marker per pane the instant that pane's
// composer is empty. It exits itself once no patrón panes remain.

const (
	daemonTick = 3 * time.Second
	daemonIdle = 60 * time.Second // exit after this long with no registered panes
)

type paneState struct {
	pending map[string]bool
}

type daemon struct {
	mu              sync.Mutex
	blockedReported map[string]bool
	exitedReported  map[string]bool
	panes           map[string]*paneState
	version         string
	lastNonEmpty    time.Time
	// connected is true while the herdr event stream is live. When true the
	// daemon is PURELY event-driven and never polls sicario panes (see tick):
	// an `agent get` capture on a streaming TUI forces a repaint, which used to
	// flood watched sicario panes with duplicated frames. It is only false during
	// an actual herdr outage, when the poll backstop takes over.
	connected atomic.Bool
}

func newDaemon() *daemon {
	return &daemon{
		blockedReported: map[string]bool{},
		exitedReported:  map[string]bool{},
		panes:           map[string]*paneState{},
		version:         resolvedExe(),
		lastNonEmpty:    time.Now(),
	}
}

// baseline consumes any already-outstanding replies / marks already-settled
// sicarios so a finish that PREDATES this daemon isn't (re-)announced at startup.
func (d *daemon) baseline() {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, s := range listSicarios() {
		switch agentStatus(s.ID) {
		case "idle", "done":
			replyResolve(s.ID) // consume silently: nothing to report for old work
		case "blocked":
			d.blockedReported[s.ID] = true
		case "exited":
			d.exitedReported[s.ID] = true
		}
	}
}

// observe applies one status observation (from the event stream OR the poll
// backstop). Reporting is REPLY-CORRELATED: a settle to idle/done reports at most
// ONCE per outstanding order/brief (via the idempotent replyResolve), so the
// working<->done flaps and post-answer recap steps claude emits within a SINGLE
// task can no longer each fire a nudge - the old double/triple-report bug.
// blocked/exited are deduped with a flag that a later `working` re-arms.
func (d *daemon) observe(id, st string) {
	if st == "" {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	switch st {
	case "idle", "done":
		if replyResolve(id) {
			d.enqueueLocked(id)
		}
	case "blocked":
		if !d.blockedReported[id] {
			d.blockedReported[id] = true
			d.enqueueLocked(id)
		}
	case "exited":
		if !d.exitedReported[id] {
			d.exitedReported[id] = true
			d.enqueueLocked(id)
		}
	case "working":
		d.blockedReported[id] = false
		d.exitedReported[id] = false
	}
}

// enqueueLocked fans a settled sicario id out to every registered pane's pending
// set. Caller must hold d.mu.
func (d *daemon) enqueueLocked(id string) {
	for _, ps := range d.panes {
		ps.pending[id] = true
	}
}

func (d *daemon) register(paneID string) {
	if paneID == "" {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if _, ok := d.panes[paneID]; !ok {
		d.panes[paneID] = &paneState{pending: map[string]bool{}}
	}
	d.lastNonEmpty = time.Now()
}

// tick runs the poll backstop, delivers due reports, prunes dead panes, and
// returns true when the daemon should exit (idle).
func (d *daemon) tick() bool {
	// Poll backstop - ONLY while the event stream is down. When it is up we are
	// purely event-driven (like the pre-daemon lookout) and never `agent get` a
	// sicario on a timer, so a working sicario's TUI is no longer force-repainted
	// every tick. Reconnects reconcile any transition missed during the gap
	// (serveConn), and observe is idempotent for idle/done via replyResolve.
	if !d.connected.Load() {
		for _, s := range listSicarios() {
			d.observe(s.ID, agentStatus(s.ID))
		}
	}

	// Snapshot the panes + their pending ids under lock, then do the slow herdr
	// I/O (composer read, send-text, enter) OUTSIDE the lock.
	type work struct {
		pane string
		ids  []string
	}
	d.mu.Lock()
	var jobs []work
	panes := make([]string, 0, len(d.panes))
	for pane, ps := range d.panes {
		panes = append(panes, pane)
		if len(ps.pending) == 0 {
			continue
		}
		ids := make([]string, 0, len(ps.pending))
		for id := range ps.pending {
			ids = append(ids, id)
		}
		jobs = append(jobs, work{pane, ids})
	}
	empty := len(d.panes) == 0
	if !empty {
		d.lastNonEmpty = time.Now()
	}
	idleExpired := empty && time.Since(d.lastNonEmpty) > daemonIdle
	d.mu.Unlock()

	// Prune panes whose patrón has closed.
	for _, pane := range panes {
		if !paneAlive(pane) {
			d.mu.Lock()
			delete(d.panes, pane)
			d.mu.Unlock()
		}
	}

	// Deliver coalesced reports, but only into an EMPTY composer.
	for _, j := range jobs {
		if !paneAlive(j.pane) {
			continue
		}
		if composerState(j.pane) != "empty" {
			continue
		}
		if deliverReport(j.pane, j.ids) {
			d.mu.Lock()
			if ps, ok := d.panes[j.pane]; ok {
				for _, id := range j.ids {
					delete(ps.pending, id)
				}
			}
			d.mu.Unlock()
			dlogf("delivered settled %v", j.ids)
		} else {
			dlogf("deferred %v (composer busy or submit unconfirmed)", j.ids)
		}
	}

	return idleExpired
}

// deliverReport types the sanitized marker into a pane and confirms it was
// SUBMITTED (our marker text left the live composer row). Returns false to keep
// the ids queued. Confirming on our own marker text - not a generic "pending"
// verdict - means a post-submit ghost suggestion can never trick us into
// re-typing an already-delivered report (the old double/triple-report bug).
func deliverReport(pane string, ids []string) bool {
	msg := reportMarker(ids)
	// Close the race window: re-check the composer is empty right before typing.
	if composerState(pane) != "empty" {
		return false
	}
	if !herdrOK("pane", "send-text", pane, msg) {
		return false
	}
	time.Sleep(1200 * time.Millisecond) // let the pasted text settle before Enter
	return pressEnterUntilSubmitted(pane, "[cartel] settled", 3)
}

func dlogf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "cartel daemon: "+format+"\n", args...)
}

func (d *daemon) tickLoop(ctx context.Context, cancel context.CancelFunc) {
	t := time.NewTicker(daemonTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if d.tick() {
				cancel()
				return
			}
		}
	}
}

// ---------------------------------------------------------------------------
// IPC
// ---------------------------------------------------------------------------

type ipcReq struct {
	Method string `json:"method"`
	PaneID string `json:"pane_id,omitempty"`
}

type ipcResp struct {
	OK      bool   `json:"ok"`
	Version string `json:"version,omitempty"`
}

func (d *daemon) handleConn(conn net.Conn, cancel context.CancelFunc) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	var req ipcReq
	if json.NewDecoder(conn).Decode(&req) != nil {
		return
	}
	resp := ipcResp{OK: true, Version: d.version}
	switch req.Method {
	case "register":
		d.register(req.PaneID)
	case "ping", "version":
		// resp already carries ok+version
	case "shutdown":
		_ = json.NewEncoder(conn).Encode(resp)
		cancel()
		return
	default:
		resp.OK = false
	}
	_ = json.NewEncoder(conn).Encode(resp)
}

// cmdDaemon runs the long-lived watcher. Singleton by socket bind: if a live
// daemon already holds the socket, exit.
func cmdDaemon(_ []string) {
	if resp, ok := daemonRequest(ipcReq{Method: "ping"}); ok && resp.OK {
		return // another daemon already running
	}
	_ = os.Remove(daemonSock) // clear a stale socket
	ln, err := net.Listen("unix", daemonSock)
	if err != nil {
		die("daemon: cannot bind %s: %v", daemonSock, err)
	}
	_ = os.Chmod(daemonSock, 0o600)
	_ = os.WriteFile(daemonPidF, []byte(strconv.Itoa(os.Getpid())), 0o600)
	fmt.Fprintf(os.Stderr, "cartel daemon: up (pid %d, version %s)\n", os.Getpid(), resolvedExe())

	ctx, cancel := context.WithCancel(context.Background())
	cleanup := func() {
		ln.Close()
		_ = os.Remove(daemonSock)
		_ = os.Remove(daemonPidF)
	}
	defer cleanup()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		select {
		case <-sig:
			cancel()
		case <-ctx.Done():
		}
		ln.Close()
	}()

	d := newDaemon()
	d.baseline()
	go streamTransitions(ctx, d.observe, d.connected.Store)
	go d.tickLoop(ctx, cancel)

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		go d.handleConn(conn, cancel)
	}
}

// ---------------------------------------------------------------------------
// Client side (used by `cartel patron`)
// ---------------------------------------------------------------------------

func daemonRequest(req ipcReq) (ipcResp, bool) {
	c, err := net.DialTimeout("unix", daemonSock, time.Second)
	if err != nil {
		return ipcResp{}, false
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	if json.NewEncoder(c).Encode(req) != nil {
		return ipcResp{}, false
	}
	var resp ipcResp
	if json.NewDecoder(c).Decode(&resp) != nil {
		return ipcResp{}, false
	}
	return resp, true
}

// ensureDaemon makes sure a daemon of THIS binary's version is running: it
// connects and version-handshakes, replacing an older daemon (post nix-rebuild)
// by asking it to shut down and spawning a fresh one.
func ensureDaemon() {
	if resp, ok := daemonRequest(ipcReq{Method: "version"}); ok {
		if resp.Version == resolvedExe() {
			return
		}
		daemonRequest(ipcReq{Method: "shutdown"})
		for i := 0; i < 30; i++ {
			if _, ok := daemonRequest(ipcReq{Method: "ping"}); !ok {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	spawnDaemon()
	for i := 0; i < 30; i++ {
		if _, ok := daemonRequest(ipcReq{Method: "ping"}); ok {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// spawnDaemon starts a detached `cartel daemon`. It uses os.Executable (the
// symlink path) so a rebuild-updated `cartel` symlink is followed on next spawn.
func spawnDaemon() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	logf, _ := os.OpenFile(daemonLog, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	cmd := exec.Command(exe, "daemon")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Env = os.Environ()
	if logf != nil {
		cmd.Stdout = logf
		cmd.Stderr = logf
	}
	if cmd.Start() == nil {
		_ = cmd.Process.Release()
	}
	if logf != nil {
		logf.Close()
	}
}

// daemonRegister ensures the daemon is up and registers a patrón pane with it.
func daemonRegister(paneID string) {
	ensureDaemon()
	daemonRequest(ipcReq{Method: "register", PaneID: paneID})
}
