// cartel-events is the event-driven transport half of `cartel lookout`.
//
// It maintains ONE AF_UNIX connection to herdr's control socket, subscribes to
// pane.agent_status_changed for every sicario pane recorded under the cartel
// state dir, and prints one TAB-separated "<id>\t<status>" line per transition
// to stdout (flushed), so the bash side can react sub-second. It holds NO
// supervision policy: bash owns bell/toast/nudge/reply-correlation.
//
// Resilience:
//   - herdr 0.7.3 accepts exactly ONE events.subscribe per connection; a SECOND
//     subscribe makes it close the connection (verified empirically). So we send
//     ALL currently-good panes in a SINGLE combined request, and treat any change
//     to the good-pane set as a reason to RECONNECT with a fresh combined request
//     (never a second subscribe on a live conn).
//   - herdr replies to a bad/stale pane with a per-subscription error whose id
//     encodes the subscription INDEX ("<reqID>:sub:<i>:...") and then closes the
//     connection; we map that index back to the offending pane, QUARANTINE it,
//     and reconnect with the rest - so one stale sicario can't kill the stream.
//   - Rescans the state dir every 2s to notice added/removed sicarios.
//   - Reconnects with backoff on any drop. Gives up (non-zero exit) only after a
//     run of unexplained failures, telling bash to fall back to polling.
//
// Wire protocol (verified: herdr 0.7.3, newline-delimited JSON over AF_UNIX):
//   request: {"id":R,"method":"events.subscribe","params":{"subscriptions":[
//            {"type":"pane.agent_status_changed","pane_id":P0},{...P1}, ...]}}\n
//   ack:     {"id":R,"result":{"type":"subscription_started"}}\n     (ignored)
//   error:   {"id":"R:sub:<i>:...","error":{...}}\n  then server closes the conn
//   stream:  {"event":"pane.agent_status_changed",
//            "data":{"pane_id","workspace_id","agent_status","agent",...}}\n
//
// Usage:
//   cartel-events --state <dir> [--socket <path>]                 # stream (lookout)
//   cartel-events --state <dir> --await <id> [--timeout <secs>]   # one-shot (await)
//
// In --await mode it blocks on ONE subscription until <id> settles and exits with
// a status code (0 idle/done, 2 timeout, 3 blocked, 4 exited, 5 setup error), so
// `cartel await` reacts to the real transition instead of polling herdr.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	rescanInterval = 2 * time.Second
	dialTimeout    = 5 * time.Second
	healthyUptime  = 5 * time.Second // a drop after this long counts as healthy
	// Consecutive unexplained failures -> exit so the bash supervisor can cover
	// the gap with polling and then re-enter event mode. Kept low because that
	// fallback is now SELF-HEALING (not a permanent downgrade), so handing control
	// back quickly beats churning on a broken connection here.
	maxUnexplained = 6
	backoffStart   = 250 * time.Millisecond
	backoffMax     = 5 * time.Second
)

type subscription struct {
	Type   string `json:"type"`
	PaneID string `json:"pane_id"`
}

type subscribeRequest struct {
	ID     string `json:"id"`
	Method string `json:"method"`
	Params struct {
		Subscriptions []subscription `json:"subscriptions"`
	} `json:"params"`
}

type incoming struct {
	Event string           `json:"event"`
	ID    string           `json:"id"`
	Error *json.RawMessage `json:"error"`
	Data  struct {
		PaneID      string `json:"pane_id"`
		AgentStatus string `json:"agent_status"`
		Agent       string `json:"agent"`
	} `json:"data"`
}

// discoverSocket resolves the herdr control socket: flag, then env, then the
// default session's socket_path from `herdr session list --json`.
func discoverSocket(flagSock string) string {
	if flagSock != "" {
		return flagSock
	}
	if s := os.Getenv("HERDR_SOCKET_PATH"); s != "" {
		return s
	}
	out, err := exec.Command("herdr", "session", "list", "--json").Output()
	if err != nil {
		return ""
	}
	var v struct {
		Sessions []struct {
			Default    bool   `json:"default"`
			SocketPath string `json:"socket_path"`
		} `json:"sessions"`
	}
	if json.Unmarshal(out, &v) != nil {
		return ""
	}
	for _, s := range v.Sessions {
		if s.Default && s.SocketPath != "" {
			return s.SocketPath
		}
	}
	for _, s := range v.Sessions {
		if s.SocketPath != "" {
			return s.SocketPath
		}
	}
	return ""
}

// scanState reads <dir>/*.json (top level only; reply records live in a
// replies/ subdir) and returns pane_id -> sicario id.
func scanState(dir string) map[string]string {
	paneToID := map[string]string{}
	files, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var sf struct {
			ID     string `json:"id"`
			PaneID string `json:"pane_id"`
		}
		if json.Unmarshal(b, &sf) != nil || sf.ID == "" || sf.PaneID == "" {
			continue
		}
		paneToID[sf.PaneID] = sf.ID
	}
	return paneToID
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "cartel-events: "+format+"\n", args...)
}

// outcome of serving a single connection.
type outcome int

const (
	outImmediateFail outcome = iota // dropped fast, no data, no quarantine
	outQuarantined                  // isolated a dead pane; retry is progress
	outHealthyDrop                  // was up a while or streamed data
	outIdleNoPanes                  // dropped with nothing to watch yet (benign)
)

// goodPanesFor returns the current good (non-quarantined) sicario panes from the
// state dir, SORTED so the set is comparable across rescans.
func goodPanesFor(stateDir string, bad map[string]bool, badMu *sync.Mutex) []string {
	m := scanState(stateDir)
	out := make([]string, 0, len(m))
	badMu.Lock()
	for p := range m {
		if !bad[p] {
			out = append(out, p)
		}
	}
	badMu.Unlock()
	sort.Strings(out)
	return out
}

func sameSet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// badPaneFromErr maps an error id like "ce-3:sub:1:..." to the offending pane by
// its subscription INDEX within the combined request we just sent.
func badPaneFromErr(errID string, reqPanes []string) string {
	i := strings.Index(errID, ":sub:")
	if i < 0 {
		return ""
	}
	rest := errID[i+len(":sub:"):]
	if j := strings.IndexByte(rest, ':'); j >= 0 {
		rest = rest[:j]
	}
	idx, err := strconv.Atoi(rest)
	if err != nil || idx < 0 || idx >= len(reqPanes) {
		return ""
	}
	return reqPanes[idx]
}

// serveConn subscribes ALL current good panes in ONE combined request (herdr
// closes the connection on a second subscribe), streams events until the
// connection drops, quarantines any pane herdr rejects, and reconnects whenever
// the good-pane set changes. `bad` (guarded by badMu) is the cross-connection
// set of dead panes to skip.
func serveConn(nc net.Conn, stateDir string, bad map[string]bool, badMu *sync.Mutex, readyPrinted *bool) outcome {
	paneToID := scanState(stateDir)
	reqPanes := goodPanesFor(stateDir, bad, badMu)

	// Single combined subscribe (only if we have something to watch).
	if len(reqPanes) > 0 {
		subs := make([]subscription, len(reqPanes))
		for i, p := range reqPanes {
			subs[i] = subscription{Type: "pane.agent_status_changed", PaneID: p}
		}
		var req subscribeRequest
		req.ID = "ce-sub"
		req.Method = "events.subscribe"
		req.Params.Subscriptions = subs
		if err := json.NewEncoder(nc).Encode(&req); err != nil {
			return outImmediateFail
		}
	}

	if !*readyPrinted {
		fmt.Println("@ready")
		*readyPrinted = true
	}

	// Rescan: when the good-pane set changes (a sicario recruited/buried, or a
	// pane freshly quarantined), close the conn so main reconnects with a fresh
	// combined request. We must NOT send a second subscribe on this connection.
	done := make(chan struct{})
	defer close(done)
	changed := make(chan struct{}, 1)
	go func() {
		t := time.NewTicker(rescanInterval)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				if !sameSet(goodPanesFor(stateDir, bad, badMu), reqPanes) {
					select {
					case changed <- struct{}{}:
					default:
					}
					nc.Close()
					return
				}
			}
		}
	}()

	start := time.Now()
	quarantined := false
	gotData := false
	r := bufio.NewReader(nc)
	w := bufio.NewWriter(os.Stdout)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			break
		}
		var msg incoming
		if json.Unmarshal(line, &msg) != nil {
			continue
		}
		switch {
		case msg.Event == "pane.agent_status_changed":
			id := paneToID[msg.Data.PaneID]
			// SECURITY: only emit an id for a pane we RECORDED in the state dir.
			// Do NOT fall back to msg.Data.Agent (the herdr-reported agent label):
			// an agent can rename itself, and this id flows into the patrón's
			// trusted report channel. An event for an unrecorded pane is dropped.
			if id == "" || msg.Data.AgentStatus == "" {
				continue
			}
			fmt.Fprintf(w, "%s\t%s\n", id, msg.Data.AgentStatus)
			w.Flush()
			gotData = true
		case msg.Error != nil && msg.ID != "":
			if pane := badPaneFromErr(msg.ID, reqPanes); pane != "" {
				badMu.Lock()
				bad[pane] = true
				badMu.Unlock()
				logf("quarantining unreachable pane %s (sicario %q); resubscribing the rest", pane, paneToID[pane])
				quarantined = true
			}
		}
	}

	// A drop caused by the pane set changing is benign progress, not a failure.
	select {
	case <-changed:
		return outHealthyDrop
	default:
	}
	switch {
	case quarantined:
		return outQuarantined
	case gotData || time.Since(start) >= healthyUptime:
		return outHealthyDrop
	case len(reqPanes) == 0:
		// Nothing to watch yet (patrón seated, no sicarios). herdr may close such
		// an idle connection quickly - normal, so don't burn the give-up budget.
		return outIdleNoPanes
	default:
		return outImmediateFail
	}
}

// agentStatusExec snapshots one agent's status via `herdr agent get`. Returns
// "exited" if the agent is gone, "" if the reply couldn't be parsed.
func agentStatusExec(id string) string {
	out, err := exec.Command("herdr", "agent", "get", id).Output()
	if err != nil {
		return "exited"
	}
	var v struct {
		Result struct {
			Agent struct {
				AgentStatus string `json:"agent_status"`
			} `json:"agent"`
		} `json:"result"`
	}
	if json.Unmarshal(out, &v) != nil {
		return ""
	}
	return v.Result.Agent.AgentStatus
}

// paneForSicario resolves a sicario id to its pane from the state dir.
func paneForSicario(stateDir, id string) string {
	for pane, sid := range scanState(stateDir) {
		if sid == id {
			return pane
		}
	}
	return ""
}

// classifyAwait maps an agent status to an await exit code and whether it is a
// terminal state. It prints the resolved status (for the bash "replied (%s)"
// line) only for idle/done; bash prints its own message for blocked/exited.
//
//	0 = idle|done (settled)   2 = timeout   3 = blocked   4 = exited
func classifyAwait(status string) (code int, done bool) {
	switch status {
	case "idle", "done":
		fmt.Println(status)
		return 0, true
	case "blocked":
		return 3, true
	case "exited":
		return 4, true
	}
	return 0, false // working/unknown/empty -> keep waiting
}

// runAwait blocks until sicario <id> settles (idle/done/blocked/exited) or the
// timeout elapses, using ONE AF_UNIX subscription. It is race-free by design:
// it subscribes, waits for the ack, and only THEN snapshots current status - so a
// transition that lands between snapshot and subscription can't be missed. Exit
// code 5 means "setup failed, caller should fall back to polling".
func runAwait(awaitID, stateDir, sockFlag string, timeout time.Duration) int {
	pane := paneForSicario(stateDir, awaitID)
	if pane == "" {
		logf("await: unknown sicario %q (no pane in state dir)", awaitID)
		return 5
	}
	sock := discoverSocket(sockFlag)
	if sock == "" {
		logf("await: could not resolve herdr socket")
		return 5
	}
	nc, err := net.DialTimeout("unix", sock, dialTimeout)
	if err != nil {
		logf("await: connect failed: %v", err)
		return 5
	}
	defer nc.Close()
	_ = nc.SetReadDeadline(time.Now().Add(timeout))
	r := bufio.NewReader(nc)
	enc := json.NewEncoder(nc)

	var req subscribeRequest
	req.ID = "await-1"
	req.Method = "events.subscribe"
	req.Params.Subscriptions = []subscription{{Type: "pane.agent_status_changed", PaneID: pane}}
	if err := enc.Encode(&req); err != nil {
		logf("await: subscribe failed: %v", err)
		return 5
	}

	// Wait for the subscription ack before snapshotting.
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			logf("await: waiting for subscription ack: %v", err)
			return 5
		}
		var msg incoming
		if json.Unmarshal(line, &msg) != nil {
			continue
		}
		if strings.HasPrefix(msg.ID, "await-1") {
			if msg.Error != nil {
				logf("await: subscription rejected for pane %s", pane)
				return 5
			}
			break // subscription_started
		}
		// A transition that arrives before the ack still counts.
		if msg.Event == "pane.agent_status_changed" && msg.Data.PaneID == pane {
			if code, done := classifyAwait(msg.Data.AgentStatus); done {
				return code
			}
		}
	}

	// Snapshot AFTER the subscription is live: if it already settled, report now.
	if code, done := classifyAwait(agentStatusExec(awaitID)); done {
		return code
	}

	// Otherwise wait for the next transition on this pane.
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				return 2 // timeout
			}
			logf("await: stream error: %v", err)
			return 5
		}
		var msg incoming
		if json.Unmarshal(line, &msg) != nil {
			continue
		}
		if msg.Event == "pane.agent_status_changed" && msg.Data.PaneID == pane {
			if code, done := classifyAwait(msg.Data.AgentStatus); done {
				return code
			}
		}
	}
}

func main() {
	var stateDir, sockFlag, awaitID string
	var timeoutSec int
	flag.StringVar(&stateDir, "state", "", "cartel state dir")
	flag.StringVar(&sockFlag, "socket", "", "herdr control socket path")
	flag.StringVar(&awaitID, "await", "", "one-shot: block until this sicario settles, then exit")
	flag.IntVar(&timeoutSec, "timeout", 180, "await timeout in seconds (with --await)")
	flag.Parse()
	if stateDir == "" {
		logf("--state is required")
		os.Exit(2)
	}

	// One-shot await mode: the sync half of reply correlation, event-driven.
	if awaitID != "" {
		os.Exit(runAwait(awaitID, stateDir, sockFlag, time.Duration(timeoutSec)*time.Second))
	}

	bad := map[string]bool{}
	var badMu sync.Mutex
	readyPrinted := false
	unexplained := 0
	backoff := backoffStart

	for {
		sock := discoverSocket(sockFlag)
		if sock == "" {
			logf("could not resolve herdr socket; retrying")
			unexplained++
			if unexplained >= maxUnexplained {
				logf("giving up after %d attempts", unexplained)
				os.Exit(2)
			}
			time.Sleep(backoff)
			backoff = nextBackoff(backoff)
			continue
		}

		nc, err := net.DialTimeout("unix", sock, dialTimeout)
		if err != nil {
			logf("connect failed: %v", err)
			unexplained++
			if unexplained >= maxUnexplained {
				logf("giving up after %d connect failures", unexplained)
				os.Exit(4)
			}
			time.Sleep(backoff)
			backoff = nextBackoff(backoff)
			continue
		}

		res := serveConn(nc, stateDir, bad, &badMu, &readyPrinted)
		nc.Close()

		switch res {
		case outQuarantined:
			unexplained = 0
			backoff = backoffStart
			// reconnect immediately: quarantining a dead pane is progress
		case outHealthyDrop:
			unexplained = 0
			backoff = backoffStart
			logf("connection dropped; reconnecting")
			time.Sleep(backoffStart)
		case outIdleNoPanes:
			// No sicarios to watch yet: wait a rescan interval and retry WITHOUT
			// counting toward give-up, so the stream survives an arbitrarily long
			// gap between seating the patrón and recruiting the first sicario.
			unexplained = 0
			backoff = backoffStart
			time.Sleep(rescanInterval)
		default: // outImmediateFail
			unexplained++
			if unexplained >= maxUnexplained {
				logf("giving up after %d unexplained drops", unexplained)
				os.Exit(4)
			}
			time.Sleep(backoff)
			backoff = nextBackoff(backoff)
		}
	}
}

func nextBackoff(b time.Duration) time.Duration {
	b *= 2
	if b > backoffMax {
		return backoffMax
	}
	return b
}
