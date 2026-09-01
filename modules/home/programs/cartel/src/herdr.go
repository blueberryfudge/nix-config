package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"time"
)

// All herdr access goes through this thin wrapper: mutations shell out to the
// `herdr` CLI (it handles arg-escaping + JSON), while the event stream (events.go)
// talks the AF_UNIX socket directly. cartel mutates and DESTROYS containers, so
// every call is pinned to ONE explicit server via HERDR_SOCKET_PATH (see
// pinSocket) - silently reaching a different server when several run is dangerous.

// pinSocket resolves the herdr control socket once and exports it, unless the
// caller already inherited one (the common in-pane case). Exporting (not a
// --session flag) also means it can never leak into an `agent start ... -- <argv>`
// passthrough, and the daemon/event stream inherit it.
func pinSocket() {
	if os.Getenv("HERDR_SOCKET_PATH") != "" {
		return
	}
	out, err := exec.Command("herdr", "session", "list", "--json").Output()
	if err != nil {
		return
	}
	var v struct {
		Sessions []struct {
			Default    bool   `json:"default"`
			SocketPath string `json:"socket_path"`
		} `json:"sessions"`
	}
	if json.Unmarshal(out, &v) != nil {
		return
	}
	sock := ""
	for _, s := range v.Sessions {
		if s.Default && s.SocketPath != "" {
			sock = s.SocketPath
			break
		}
	}
	if sock == "" {
		for _, s := range v.Sessions {
			if s.SocketPath != "" {
				sock = s.SocketPath
				break
			}
		}
	}
	if sock != "" {
		_ = os.Setenv("HERDR_SOCKET_PATH", sock)
	}
}

// herdrOut runs a herdr subcommand and returns stdout, discarding stderr.
func herdrOut(args ...string) ([]byte, error) {
	cmd := exec.Command("herdr", args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.Bytes(), err
}

// herdrOK runs a herdr subcommand for effect, swallowing output/errors.
func herdrOK(args ...string) bool {
	return exec.Command("herdr", args...).Run() == nil
}

// --- Higher-level helpers, mirroring the bash functions of the same name. ---

// agentTarget resolves a sicario id to the herdr target to address it by: its
// RECORDED pane id when we have state, else the raw argument (herdr rejects an
// ambiguous agent name, so the unique pane id is the reliable fast path).
func agentTarget(id string) string {
	if s, err := readSicario(id); err == nil && s.PaneID != "" {
		return s.PaneID
	}
	return id
}

// agentStatus returns the current herdr agent state, or "exited" when the target
// is gone. One of: working | idle | done | blocked | unknown | exited.
func agentStatus(idOrPane string) string {
	out, err := herdrOut("agent", "get", agentTarget(idOrPane))
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
	if json.Unmarshal(out, &v) != nil || v.Result.Agent.AgentStatus == "" {
		return "exited"
	}
	return v.Result.Agent.AgentStatus
}

// agentReadText returns the plain text of an agent read (JSON .result.read.text).
func agentReadText(target, source string, lines int) string {
	out, err := herdrOut("agent", "read", target, "--source", source, "--lines", itoa(lines))
	if err != nil {
		return ""
	}
	var v struct {
		Result struct {
			Read struct {
				Text string `json:"text"`
			} `json:"read"`
		} `json:"result"`
	}
	if json.Unmarshal(out, &v) != nil {
		return ""
	}
	return v.Result.Read.Text
}

// paneReadANSI returns the raw ANSI-styled tail of a pane (NOT JSON). herdr's
// `pane read --lines N` returns EMPTY when N is below the pane's viewport height,
// so callers pass a generous floor and trim locally.
func paneReadANSI(pane string, lines int) string {
	out, err := herdrOut("pane", "read", pane, "--source", "recent", "--lines", itoa(lines), "--format", "ansi")
	if err != nil {
		return ""
	}
	return string(out)
}

// paneAlive reports whether a pane still exists.
func paneAlive(pane string) bool { return herdrOK("pane", "get", pane) }

// waitStarted blocks until an agent has actually STARTED its turn (left idle) or
// gone. Fast (returns the moment it moves), bounded at ~10s. blocked counts as
// started (e.g. a trust screen). Returns: 0 started, 1 timeout, 2 exited.
func waitStarted(id string) int {
	for i := 0; i < 20; i++ {
		switch agentStatus(id) {
		case "working", "done", "blocked":
			return 0
		case "exited":
			return 2
		}
		time.Sleep(500 * time.Millisecond)
	}
	return 1
}

// onStartupGate heuristically detects a first-run trust/login/onboarding screen,
// where a brief must not be auto-typed (the human answers first).
func onStartupGate(id string) bool {
	v := agentReadText(agentTarget(id), "visible", 40)
	return startupGateRe.MatchString(strings.ToLower(v))
}

// pressEnterUntilSubmitted presses Enter until `probe` (a distinctive chunk of
// the just-typed text) is no longer sitting in the live composer row - i.e. the
// text was actually submitted - or the attempts run out. This is the EXACTLY-ONCE
// guard: it stops the instant the text is gone, so a slow status flip or a
// post-submit ghost suggestion can no longer trick us into re-pressing Enter and
// double-submitting the same prompt/marker. Returns true iff submission confirmed.
func pressEnterUntilSubmitted(pane, probe string, attempts int) bool {
	for i := 0; i < attempts; i++ {
		_ = herdrOK("pane", "send-keys", pane, "enter")
		time.Sleep(800 * time.Millisecond)
		if !composerRowContains(pane, probe) {
			return true
		}
	}
	return false
}

// submitProbe returns a short, rune-safe, distinctive prefix of text to look for
// in the composer (its first non-empty line, capped at ~32 runes).
func submitProbe(text string) string {
	for _, ln := range strings.Split(text, "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" {
			continue
		}
		r := []rune(ln)
		if len(r) > 32 {
			r = r[:32]
		}
		return string(r)
	}
	return ""
}

// submitPrompt sends a prompt to an agent and submits it exactly once. herdr's
// `agent send` types the text but does NOT press Enter, and TUIs need the pasted
// text to settle before Enter registers (empirically ~1.5s for claude).
func submitPrompt(id, agentPane, text string) bool {
	if !herdrOK("agent", "send", agentTarget(id), text) {
		return false
	}
	time.Sleep(1200 * time.Millisecond)
	if pressEnterUntilSubmitted(agentPane, submitProbe(text), 4) {
		return true
	}
	// Couldn't confirm via the composer (e.g. wrapped text); if the agent moved
	// off idle the prompt clearly landed. Best-effort either way.
	switch agentStatus(id) {
	case "working", "done", "blocked":
		return true
	}
	return true
}

// nudgeAgent injects a message into a NAMED agent's session and submits it (used
// by the foreground lookout's --notify-agent). Best-effort.
func nudgeAgent(target, text string) {
	out, err := herdrOut("agent", "get", target)
	if err != nil {
		return
	}
	var v struct {
		Result struct {
			Agent struct {
				PaneID string `json:"pane_id"`
			} `json:"agent"`
		} `json:"result"`
	}
	if json.Unmarshal(out, &v) != nil || v.Result.Agent.PaneID == "" {
		return
	}
	if !herdrOK("agent", "send", target, text) {
		return
	}
	time.Sleep(1200 * time.Millisecond)
	_ = herdrOK("pane", "send-keys", v.Result.Agent.PaneID, "enter")
}

// resolveTargetWS resolves the Herdr workspace to host tab-mode sicarios: the
// pane's own workspace when cartel runs inside Herdr, else the focused workspace.
func resolveTargetWS() string {
	if w := os.Getenv("HERDR_WORKSPACE_ID"); w != "" {
		return w
	}
	out, err := herdrOut("workspace", "list")
	if err != nil {
		return ""
	}
	var v struct {
		Result struct {
			Workspaces []struct {
				WorkspaceID string `json:"workspace_id"`
				Focused     bool   `json:"focused"`
			} `json:"workspaces"`
		} `json:"result"`
	}
	if json.Unmarshal(out, &v) != nil {
		return ""
	}
	for _, w := range v.Result.Workspaces {
		if w.Focused {
			return w.WorkspaceID
		}
	}
	return ""
}
