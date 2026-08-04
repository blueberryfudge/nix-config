package main

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Event transport (absorbed from the former standalone cartel-events binary).
// Maintains ONE AF_UNIX connection to herdr's control socket, subscribes to
// pane.agent_status_changed for every recorded sicario pane, and reports each
// transition via a callback. It holds NO supervision policy - the daemon owns
// dedup/report/delivery.
//
// herdr 0.7.3 accepts exactly ONE events.subscribe per connection (a second one
// closes the connection), so we send ALL currently-good panes in a SINGLE
// combined request and RECONNECT with a fresh request whenever the good-pane set
// changes. A per-subscription error id ("<reqID>:sub:<i>:...") lets us map a
// rejection back to the offending pane and QUARANTINE only it.

const (
	rescanInterval = 2 * time.Second
	dialTimeout    = 5 * time.Second
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

func discoverSocket() string {
	if s := os.Getenv("HERDR_SOCKET_PATH"); s != "" {
		return s
	}
	out, err := herdrOut("session", "list", "--json")
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

// goodPanes returns the current good (non-quarantined) sicario panes, SORTED so
// the set is comparable across rescans.
func goodPanes(bad map[string]bool) []string {
	out := make([]string, 0)
	for p := range paneToID() {
		if !bad[p] {
			out = append(out, p)
		}
	}
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

// badPaneFromErr maps an error id like "ce-sub:sub:1:..." to the offending pane
// by its subscription INDEX within the combined request we just sent.
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

// serveConn subscribes ALL current good panes in one combined request, streams
// transitions via emit until the connection drops, quarantines any pane herdr
// rejects, and returns when the good-pane set changes or the connection ends.
func serveConn(ctx context.Context, nc net.Conn, bad map[string]bool, emit func(id, status string)) {
	// Snapshot pane->id once: a change to the good-pane set forces a reconnect
	// (below), so within this connection the mapping is stable.
	p2id := paneToID()
	reqPanes := goodPanes(bad)
	if len(reqPanes) > 0 {
		subs := make([]subscription, len(reqPanes))
		for i, p := range reqPanes {
			subs[i] = subscription{Type: "pane.agent_status_changed", PaneID: p}
		}
		var req subscribeRequest
		req.ID = "ce-sub"
		req.Method = "events.subscribe"
		req.Params.Subscriptions = subs
		if json.NewEncoder(nc).Encode(&req) != nil {
			return
		}
	}

	// Close the conn when the good-pane set changes (recruit/bury/quarantine) so
	// the caller reconnects with a fresh combined request - never a second
	// subscribe on this connection.
	done := make(chan struct{})
	defer close(done)
	go func() {
		t := time.NewTicker(rescanInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				nc.Close()
				return
			case <-done:
				return
			case <-t.C:
				if !sameSet(goodPanes(bad), reqPanes) {
					nc.Close()
					return
				}
			}
		}
	}()

	r := bufio.NewReader(nc)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return
		}
		var msg incoming
		if json.Unmarshal(line, &msg) != nil {
			continue
		}
		switch {
		case msg.Event == "pane.agent_status_changed":
			// SECURITY: only emit an id for a pane we RECORDED. Do NOT fall back to
			// msg.Data.Agent (the herdr-reported label): an agent can rename itself,
			// and this id flows into the patrón's trusted report channel.
			id := p2id[msg.Data.PaneID]
			if id == "" || msg.Data.AgentStatus == "" {
				continue
			}
			emit(id, msg.Data.AgentStatus)
		case msg.Error != nil && msg.ID != "":
			if pane := badPaneFromErr(msg.ID, reqPanes); pane != "" {
				bad[pane] = true
			}
		}
	}
}

// streamTransitions reconnects forever (with backoff), calling emit for each
// transition, until ctx is cancelled. Unlike the old standalone binary it never
// "gives up": the daemon pairs this with a polling backstop, so a persistent
// herdr outage degrades to polling without ever abandoning event mode.
func streamTransitions(ctx context.Context, emit func(id, status string)) {
	bad := map[string]bool{}
	backoff := backoffStart
	for {
		if ctx.Err() != nil {
			return
		}
		sock := discoverSocket()
		if sock == "" {
			if sleepCtx(ctx, backoff) {
				return
			}
			backoff = nextBackoff(backoff)
			continue
		}
		nc, err := net.DialTimeout("unix", sock, dialTimeout)
		if err != nil {
			if sleepCtx(ctx, backoff) {
				return
			}
			backoff = nextBackoff(backoff)
			continue
		}
		serveConn(ctx, nc, bad, emit)
		nc.Close()
		backoff = backoffStart
		if sleepCtx(ctx, backoffStart) {
			return
		}
	}
}

// sleepCtx sleeps for d or until ctx is done; returns true if ctx ended.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return true
	case <-t.C:
		return false
	}
}

func nextBackoff(b time.Duration) time.Duration {
	b *= 2
	if b > backoffMax {
		return backoffMax
	}
	return b
}

// awaitSettle blocks until sicario <id> settles (idle/done/blocked/exited) or the
// timeout elapses, using ONE AF_UNIX subscription. Race-free: subscribe, wait for
// the ack, THEN snapshot, so a transition between snapshot and subscription can't
// be missed. Returns (code, status): 0 idle|done, 2 timeout, 3 blocked, 4 exited,
// 5 setup failure (caller falls back to polling).
func awaitSettle(id string, timeout time.Duration) (int, string) {
	pane := ""
	for p, sid := range paneToID() {
		if sid == id {
			pane = p
			break
		}
	}
	if pane == "" {
		return 5, ""
	}
	sock := discoverSocket()
	if sock == "" {
		return 5, ""
	}
	nc, err := net.DialTimeout("unix", sock, dialTimeout)
	if err != nil {
		return 5, ""
	}
	defer nc.Close()
	_ = nc.SetReadDeadline(time.Now().Add(timeout))
	r := bufio.NewReader(nc)

	var req subscribeRequest
	req.ID = "await-1"
	req.Method = "events.subscribe"
	req.Params.Subscriptions = []subscription{{Type: "pane.agent_status_changed", PaneID: pane}}
	if json.NewEncoder(nc).Encode(&req) != nil {
		return 5, ""
	}

	classify := func(status string) (int, string, bool) {
		switch status {
		case "idle", "done":
			return 0, status, true
		case "blocked":
			return 3, "", true
		case "exited":
			return 4, "", true
		}
		return 0, "", false
	}

	// Wait for the ack before snapshotting.
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return 5, ""
		}
		var msg incoming
		if json.Unmarshal(line, &msg) != nil {
			continue
		}
		if strings.HasPrefix(msg.ID, "await-1") {
			if msg.Error != nil {
				return 5, ""
			}
			break
		}
		if msg.Event == "pane.agent_status_changed" && msg.Data.PaneID == pane {
			if code, st, done := classify(msg.Data.AgentStatus); done {
				return code, st
			}
		}
	}

	// Snapshot AFTER the subscription is live.
	if code, st, done := classify(agentStatus(id)); done {
		return code, st
	}

	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				return 2, ""
			}
			return 5, ""
		}
		var msg incoming
		if json.Unmarshal(line, &msg) != nil {
			continue
		}
		if msg.Event == "pane.agent_status_changed" && msg.Data.PaneID == pane {
			if code, st, done := classify(msg.Data.AgentStatus); done {
				return code, st
			}
		}
	}
}
