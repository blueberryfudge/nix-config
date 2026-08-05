package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// kindExec maps a --kind to the interactive CLI executable Herdr should launch.
func kindExec(kind string) (string, bool) {
	switch kind {
	case "cursor":
		return "cursor-agent", true
	case "claude":
		return "claude", true
	case "pi":
		return "pi", true
	}
	return "", false
}

// --- git helpers (fail-closed teardown guards) ---

func gitOut(dir string, args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).Output()
	return strings.TrimSpace(string(out)), err
}

func gitOK(dir string, args ...string) bool {
	return exec.Command("git", append([]string{"-C", dir}, args...)...).Run() == nil
}

func worktreeDirty(checkout string) bool {
	out, err := gitOut(checkout, "status", "--porcelain")
	return err == nil && out != ""
}

// branchHasUnpushed reports whether <branch> has commits that exist on no remote.
func branchHasUnpushed(cwd, br string) bool {
	if !gitOK(cwd, "show-ref", "--verify", "--quiet", "refs/heads/"+br) {
		return false
	}
	if rem, _ := gitOut(cwd, "remote"); rem == "" {
		return false // no remote: nothing to push to
	}
	n, _ := gitOut(cwd, "rev-list", "--count", br, "--not", "--remotes")
	c, _ := strconv.Atoi(n)
	return c > 0
}

// destroyContainer tears down a just-created container after a failed launch (or
// on bury), so we never orphan a workspace, tab, worktree checkout, or branch.
func destroyContainer(container string, worktree bool, wsid, tabid, cwd, checkout, id string) {
	switch {
	case container == "tab":
		if tabid != "" {
			herdrOK("tab", "close", tabid)
		}
		if worktree && checkout != "" && isDir(checkout) {
			gitOK(cwd, "worktree", "remove", "--force", checkout)
			gitOK(cwd, "branch", "-D", "cartel/"+id)
		}
	case worktree:
		herdrOK("worktree", "remove", "--workspace", wsid, "--force")
		gitOK(cwd, "branch", "-D", "cartel/"+id)
	default:
		herdrOK("workspace", "close", wsid)
	}
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// ---------------------------------------------------------------------------
// recruit
// ---------------------------------------------------------------------------

func cmdRecruit(args []string) {
	if len(args) == 0 {
		die("recruit: missing <id>")
	}
	id := args[0]
	args = args[1:]

	// Default --cwd to the patrón's target repo when set (CARTEL_TARGET), so the
	// patrón can run `cartel recruit ...` BARE (claude/cursor refuse to
	// auto-approve any command containing shell expansion).
	cwd := envOr("CARTEL_TARGET", "")
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	kind, execOverride, brief, briefFile := "", "", "", ""
	worktree := false
	container := envOr("CARTEL_DEFAULT_CONTAINER", "workspace")
	var extra []string

	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--kind":
			kind = next(args, &i)
		case "--exec":
			execOverride = next(args, &i)
		case "--cwd":
			cwd = next(args, &i)
		case "--worktree":
			worktree = true
		case "--tab":
			container = "tab"
		case "--workspace":
			container = "workspace"
		case "--brief":
			brief = next(args, &i)
		case "--brief-file":
			briefFile = next(args, &i)
		case "--":
			extra = append(extra, args[i+1:]...)
			i = len(args)
		default:
			die("recruit: unknown option '%s' (put agent args after --)", args[i])
		}
	}

	if container != "workspace" && container != "tab" {
		die("invalid container '%s' (workspace|tab)", container)
	}
	if !validID(id) {
		die("invalid id '%s' (must match [a-z][a-z0-9_-]{0,31})", id)
	}
	if kind == "" {
		die("recruit: --kind is required (cursor|claude)")
	}
	// Refuse pi sicarios: pi has NO shell-guard hook wired, so a pi sicario would
	// run FULLY unguarded. Gate it here rather than ship a false guarantee.
	if kind == "pi" {
		die("recruit: --kind pi is refused (no shell-guard hook exists for pi; a pi sicario would be unguarded). Use claude or cursor.")
	}
	execCmd, ok := kindExec(kind)
	if !ok {
		die("unsupported --kind '%s' (cursor|claude)", kind)
	}
	// --exec is a foot-gun: whatever it names becomes the pane process. Restrict it
	// to a bare command name (no path, no spaces) on a small allowlist, so it can
	// only ever be a real agent CLI or a wrapper the operator explicitly trusts.
	if execOverride != "" {
		if strings.ContainsAny(execOverride, "/ \t") {
			die("recruit: --exec must be a bare command name on the allowlist (no paths or spaces)")
		}
		if !execAllowed(execOverride) {
			die("recruit: --exec '%s' is not on the allowlist (opt in via CARTEL_EXEC_ALLOW='name ...'); refusing to launch an unguarded process as a sicario", execOverride)
		}
		execCmd = execOverride
	}
	if _, err := exec.LookPath(execCmd); err != nil {
		die("executable '%s' not found on PATH (for --kind %s)", execCmd, kind)
	}
	if !isDir(cwd) {
		die("cwd not a directory: %s", cwd)
	}
	if abs, err := filepath.Abs(cwd); err == nil {
		cwd = abs
	}
	if fileExists(stateFile(id)) {
		die("sicario '%s' already exists (cartel bury %s first)", id, id)
	}
	if agentStatus(id) != "exited" {
		die("an agent named '%s' is already live in Herdr", id)
	}
	// A retained report from a PREVIOUS sicario with this id must never be read
	// as the new one's result: rotate it aside (kept once as .old).
	if fileExists(reportFile(id)) {
		_ = os.Rename(reportFile(id), reportFile(id)+".old")
	}
	if briefFile != "" {
		b, err := os.ReadFile(briefFile)
		if err != nil {
			die("brief-file not found: %s", briefFile)
		}
		brief = string(b)
	}
	// A brief that starts with '-' is parsed by the agent CLI as a FLAG rather than
	// a prompt (e.g. --dangerously-skip-permissions), a privilege-escalation vector.
	if strings.HasPrefix(strings.TrimLeft(brief, " \t\n"), "-") {
		die("recruit: --brief must not start with '-' (it would be read as an agent flag, not a task). Reword the brief.")
	}

	if !lockAcquire(20 * time.Second) {
		die("busy: another cartel operation holds the lock (%s)", lockDir)
	}
	lockHeld := true
	defer func() {
		if lockHeld {
			lockRelease()
		}
	}()

	// 1. Session container.
	wsid, tabid, rootpane, agentcwd, checkout := "", "", "", cwd, ""
	switch {
	case container == "tab":
		wsid = resolveTargetWS()
		if wsid == "" {
			die("could not resolve a target workspace for --tab (run cartel inside your Herdr session)")
		}
		if worktree {
			if !gitOK(cwd, "rev-parse", "--is-inside-work-tree") {
				die("--worktree needs a git repo, but %s is not one", cwd)
			}
			checkout = filepath.Join(worktreeDir, filepath.Base(cwd), id)
			_ = os.MkdirAll(filepath.Dir(checkout), 0o755)
			if !gitOK(cwd, "worktree", "add", "-b", "cartel/"+id, checkout) {
				die("git worktree add failed (branch cartel/%s may already exist)", id)
			}
			agentcwd = checkout
		} else {
			agentcwd = cwd
		}
		out, err := herdrOut("tab", "create", "--workspace", wsid, "--cwd", agentcwd, "--label", "cartel-"+id, "--no-focus")
		if err != nil {
			if worktree {
				gitOK(cwd, "worktree", "remove", "--force", checkout)
			}
			die("herdr tab create failed")
		}
		tabid = jqStr(out, "result", "tab", "tab_id")
		rootpane = jqStr(out, "result", "root_pane", "pane_id")
	case worktree:
		if !gitOK(cwd, "rev-parse", "--is-inside-work-tree") {
			die("--worktree needs a git repo, but %s is not one", cwd)
		}
		out, err := herdrOut("worktree", "create", "--cwd", cwd, "--branch", "cartel/"+id, "--label", "cartel-"+id, "--no-focus", "--json")
		if err != nil {
			die("herdr worktree create failed")
		}
		checkout = jqStr(out, "result", "worktree", "path")
		agentcwd = checkout
		if agentcwd == "" {
			agentcwd = cwd
		}
		wsid = jqStr(out, "result", "workspace", "workspace_id")
		tabid = jqStr(out, "result", "tab", "tab_id")
		rootpane = jqStr(out, "result", "root_pane", "pane_id")
	default:
		out, err := herdrOut("workspace", "create", "--cwd", cwd, "--label", "cartel-"+id, "--no-focus")
		if err != nil {
			die("herdr workspace create failed")
		}
		agentcwd = cwd
		wsid = jqStr(out, "result", "workspace", "workspace_id")
		tabid = jqStr(out, "result", "tab", "tab_id")
		rootpane = jqStr(out, "result", "root_pane", "pane_id")
	}
	if wsid == "" || tabid == "" {
		die("could not read workspace/tab id from herdr response")
	}

	// 2. Launch the agent CLI. Autonomy without --dangerously-skip-permissions: the
	// CARTEL_SICARIO env tag lets the shared shell-guard hook auto-approve ordinary
	// commands and HARD-DENY the dangerous set. Worktree sicarios are isolated on
	// their own branch, so we let them apply edits without prompting.
	var autoflags []string
	switch kind {
	case "claude":
		// Report-file access: --add-dir exposes the reports dir, and the scoped
		// Write/Edit rules auto-approve writes THERE ONLY, so even a read-only
		// (non-worktree) scout can deliver its report without a prompt and without
		// gaining edit rights anywhere else.
		rule := reportWriteRule()
		autoflags = []string{"--add-dir", reportsDir,
			"--allowedTools", "Write(" + rule + "),Edit(" + rule + ")"}
		if worktree {
			autoflags = append(autoflags, "--permission-mode", "acceptEdits")
		}
	case "cursor":
		autoflags = []string{"--trust"}
		if worktree {
			autoflags = append(autoflags, "--force")
		}
	case "pi":
		autoflags = []string{"-a"}
	}
	startcmd := []string{"agent", "start", id, "--workspace", wsid, "--tab", tabid,
		"--cwd", agentcwd, "--env", "CARTEL_SICARIO=" + id, "--no-focus", "--", execCmd}
	startcmd = append(startcmd, autoflags...)
	startcmd = append(startcmd, extra...)
	// Deliver the brief as the agent's INITIAL PROMPT (trailing positional): the
	// sicario boots already working on it, skipping the readiness poll + Enter
	// dance. The report contract rides along; persisted state keeps the bare brief.
	if brief != "" {
		if kind == "claude" {
			// claude's --add-dir/--allowedTools are VARIADIC (<dirs...>): without an
			// explicit end-of-options separator they swallow the trailing brief as
			// just another flag value, and the sicario boots IDLE with no prompt.
			// The commander-style "--" closes option parsing (verified against the
			// real CLI), so the brief always lands as the initial prompt.
			startcmd = append(startcmd, "--")
		}
		startcmd = append(startcmd, brief+reportContract(id))
	}
	started, err := herdrOut(startcmd...)
	if err != nil {
		destroyContainer(container, worktree, wsid, tabid, cwd, checkout, id)
		die("herdr agent start failed (is '%s' installed and on PATH?)", execCmd)
	}
	apane := jqStr(started, "result", "agent", "pane_id")
	if apane == "" {
		destroyContainer(container, worktree, wsid, tabid, cwd, checkout, id)
		die("agent start returned no pane id: %s", strings.TrimSpace(string(started)))
	}

	// 3. Remove the now-idle root shell pane so the tab holds only the agent.
	if rootpane != "" && rootpane != apane {
		herdrOK("pane", "close", rootpane)
	}

	// 4. Persist state before the (best-effort) brief send.
	s := &Sicario{
		ID: id, Kind: kind, Exec: execCmd, Cwd: cwd, AgentCwd: agentcwd,
		Container: container, WorkspaceID: wsid, TabID: tabid, PaneID: apane,
		Worktree: worktree, Brief: brief, Created: nowUTC(),
	}
	if worktree {
		br := "cartel/" + id
		s.Branch = &br
	}
	if checkout != "" {
		s.Checkout = &checkout
	}
	if err := writeSicario(s); err != nil {
		die("failed to persist state for '%s': %v", id, err)
	}

	// Mutation done: drop the lock so other recruits proceed while we send the brief.
	lockRelease()
	lockHeld = false

	// 5. The brief was delivered as the launch prompt. Wait only until it has
	// STARTED, open the reply record for correlation, and warn on a trust screen.
	briefNote := ""
	if brief != "" {
		waitStarted(id)
		_ = replyOpen(id, brief)
		if onStartupGate(id) {
			briefNote = "\n  ! sicario is on a first-run trust/login screen; the task is queued behind it.\n" +
				"    Approve it (cartel focus " + id + " or cartel key " + id + " enter) and it will start;\n" +
				"    if it does not, resend with: cartel order " + id + " \"...\""
		}
	}

	containerInfo := "workspace=" + wsid
	if container == "tab" {
		containerInfo = fmt.Sprintf("tab=%s (workspace %s)", tabid, wsid)
	}
	wtInfo := ""
	if worktree {
		wtInfo = "  worktree=" + checkout
	}
	fmt.Printf("recruited %s  kind=%s  status=%s  %s%s%s\n",
		id, kind, agentStatus(id), containerInfo, wtInfo, briefNote)
}

// reportContract is appended to every recruit brief. It redirects the sicario's
// deliverable into its report FILE: a long answer streamed into the TUI gets
// visually duplicated in scrollback every time the pane re-renders mid-stream
// (the Don peeking at a working tab is a resize), so substance goes in the file
// and the chat reply stays tiny. Firstmate's scout-report pattern.
func reportContract(id string) string {
	p := reportFile(id)
	return "\n\n---\nDELIVERABLE CONTRACT (cartel): write your FULL findings/deliverable to the file " +
		p + " (markdown; create or overwrite it; on follow-up orders append a dated section). " +
		"ALL substance goes in that file - do NOT produce it as a long chat answer. " +
		"Your final chat reply must be at most 3 short lines: the outcome, plus 'full report: " + p + "'. " +
		"For code-change tasks the report states what changed, the branch, and how to verify."
}

// reportWriteRule renders reportsDir as a Claude Code permission-rule path glob
// ("~/..." when under $HOME, absolute "//..." otherwise), so claude sicarios can
// write their report without a permission prompt - and nothing else outside cwd.
func reportWriteRule() string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		if rel, err := filepath.Rel(home, reportsDir); err == nil && !strings.HasPrefix(rel, "..") {
			return "~/" + filepath.ToSlash(rel) + "/**"
		}
	}
	return "/" + reportsDir + "/**" // "//abs/path/**" - absolute-path rule form
}

// execAllowed reports whether a bare --exec name is on the allowlist.
func execAllowed(name string) bool {
	allow := []string{"cursor-agent", "claude", "pi"}
	allow = append(allow, strings.Fields(os.Getenv("CARTEL_EXEC_ALLOW"))...)
	for _, a := range allow {
		if a == name {
			return true
		}
	}
	return false
}

// next consumes the value after a flag at args[*i], advancing i. Returns "" if
// the flag is trailing (mirrors bash "${2:-}").
func next(args []string, i *int) string {
	if *i+1 >= len(args) {
		return ""
	}
	*i++
	return args[*i]
}

// jqStr extracts a nested string field from a herdr JSON response, "" if absent.
func jqStr(b []byte, path ...string) string {
	var v any
	if json.Unmarshal(b, &v) != nil {
		return ""
	}
	for _, k := range path {
		m, ok := v.(map[string]any)
		if !ok {
			return ""
		}
		v = m[k]
	}
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// ---------------------------------------------------------------------------
// roster / status
// ---------------------------------------------------------------------------

type rosterRow struct {
	ID          string `json:"id"`
	Kind        string `json:"kind"`
	Container   string `json:"container"`
	Worktree    bool   `json:"worktree"`
	Status      string `json:"status"`
	Reply       string `json:"reply"`
	Brief       string `json:"brief"`
	PaneID      string `json:"pane_id"`
	WorkspaceID string `json:"workspace_id"`
	TabID       string `json:"tab_id"`
	Created     string `json:"created"`
}

func rosterRowFor(s *Sicario) rosterRow {
	return rosterRow{
		ID: s.ID, Kind: s.Kind, Container: s.Container, Worktree: s.Worktree,
		Status: agentStatus(s.ID), Reply: replyState(s.ID), Brief: s.Brief,
		PaneID: s.PaneID, WorkspaceID: s.WorkspaceID, TabID: s.TabID, Created: s.Created,
	}
}

func cmdRoster(args []string) {
	jsonOut := len(args) > 0 && args[0] == "--json"
	sicarios := listSicarios()
	if jsonOut {
		rows := make([]rosterRow, 0, len(sicarios))
		for _, s := range sicarios {
			rows = append(rows, rosterRowFor(s))
		}
		b, _ := json.Marshal(rows)
		fmt.Println(string(b))
		return
	}
	if len(sicarios) == 0 {
		fmt.Println("no sicarios. cartel recruit <id> --kind <cursor|claude> ...")
		return
	}
	for _, s := range sicarios {
		wt := "ws"
		if s.Worktree {
			wt = "wt"
		}
		brief := strings.ReplaceAll(s.Brief, "\n", " ")
		if len(brief) > 52 {
			brief = brief[:52]
		}
		fmt.Printf("%-14s %-7s %-3s %-8s %s\n", s.ID, s.Kind, wt, agentStatus(s.ID), brief)
	}
}

func cmdStatus(args []string) {
	jsonOut := false
	var rest []string
	for _, a := range args {
		if a == "--json" {
			jsonOut = true
		} else {
			rest = append(rest, a)
		}
	}
	if len(rest) == 0 {
		if jsonOut {
			cmdRoster([]string{"--json"})
		} else {
			cmdRoster(nil)
		}
		return
	}
	id := rest[0]
	s, err := readSicario(id)
	if err != nil {
		die("unknown sicario '%s'", id)
	}
	if jsonOut {
		b, _ := json.Marshal(rosterRowFor(s))
		fmt.Println(string(b))
		return
	}
	st := agentStatus(id)
	fmt.Printf("%s: %s\n", id, st)
	switch st {
	case "blocked":
		fmt.Printf("  -> needs input. Inspect: cartel wire %s   Answer: cartel order %s \"...\"  or  cartel key %s <key>\n", id, id, id)
	case "exited":
		fmt.Printf("  -> agent process is gone. Retire with: cartel bury %s\n", id)
	}
}

// ---------------------------------------------------------------------------
// wire / order / key / wait / focus
// ---------------------------------------------------------------------------

func cmdWire(args []string) {
	if len(args) == 0 {
		die("wire: missing <id>")
	}
	id := args[0]
	n := 80
	if len(args) >= 3 && args[1] == "-n" {
		if v, err := strconv.Atoi(args[2]); err == nil {
			n = v
		}
	}
	if !fileExists(stateFile(id)) {
		die("unknown sicario '%s'", id)
	}
	tgt := agentTarget(id)
	t := agentReadText(tgt, "recent-unwrapped", n)
	if t == "" {
		t = agentReadText(tgt, "visible", n)
	}
	fmt.Println(t)
}

// cmdReport prints a sicario's report file - the PRIMARY way to read a settled
// sicario's result (never scrape the long answer out of the TUI: it may be
// visually duplicated in scrollback and it dies with the pane). Deliberately
// does NOT require live state: reports survive bury.
func cmdReport(args []string) {
	if len(args) == 0 {
		die("report: missing <id>")
	}
	id := args[0]
	if !validID(id) {
		die("invalid id '%s'", id)
	}
	if len(args) > 1 && args[1] == "--path" {
		fmt.Println(reportFile(id))
		return
	}
	b, err := os.ReadFile(reportFile(id))
	if err != nil {
		die("no report from '%s' (expected %s). It may not have written one yet - fall back to: cartel wire %s", id, reportFile(id), id)
	}
	os.Stdout.Write(b)
	if len(b) > 0 && b[len(b)-1] != '\n' {
		fmt.Println()
	}
}

func cmdOrder(args []string) {
	if len(args) < 2 {
		die("order: usage: cartel order <id> <text...>")
	}
	id := args[0]
	s, err := readSicario(id)
	if err != nil {
		die("unknown sicario '%s'", id)
	}
	text := strings.Join(args[1:], " ")
	if !submitPrompt(id, s.PaneID, text) {
		die("send failed")
	}
	_ = replyOpen(id, text)
}

func cmdKey(args []string) {
	if len(args) < 2 {
		die("key: usage: cartel key <id> <key...>")
	}
	id := args[0]
	s, err := readSicario(id)
	if err != nil {
		die("unknown sicario '%s'", id)
	}
	if !herdrOK(append([]string{"pane", "send-keys", s.PaneID}, args[1:]...)...) {
		die("key send failed")
	}
}

func cmdWait(args []string) {
	if len(args) == 0 {
		die("wait: missing <id>")
	}
	id := args[0]
	args = args[1:]
	if !fileExists(stateFile(id)) {
		die("unknown sicario '%s'", id)
	}
	status, timeout := "idle", ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--status":
			status = next(args, &i)
		case "--timeout":
			timeout = next(args, &i)
		default:
			die("wait: unknown option '%s'", args[i])
		}
	}
	tgt := agentTarget(id)
	var a []string
	if timeout != "" {
		a = []string{"agent", "wait", tgt, "--status", status, "--timeout", timeout}
	} else {
		a = []string{"agent", "wait", tgt, "--status", status}
	}
	cmd := exec.Command("herdr", a...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		os.Exit(1)
	}
}

func cmdFocus(args []string) {
	if len(args) == 0 {
		die("focus: missing <id>")
	}
	id := args[0]
	if !fileExists(stateFile(id)) {
		die("unknown sicario '%s'", id)
	}
	if !herdrOK("agent", "focus", agentTarget(id)) {
		die("focus failed")
	}
}

// ---------------------------------------------------------------------------
// await (sync half of reply correlation)
// ---------------------------------------------------------------------------

func cmdAwait(args []string) {
	if len(args) == 0 {
		die("await: missing <id>")
	}
	id := args[0]
	args = args[1:]
	timeout, n := 45, 40
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--timeout":
			if v, err := strconv.Atoi(next(args, &i)); err == nil {
				timeout = v
			}
		case "-n":
			if v, err := strconv.Atoi(next(args, &i)); err == nil {
				n = v
			}
		default:
			die("await: unknown option '%s'", args[i])
		}
	}
	if !fileExists(stateFile(id)) {
		die("unknown sicario '%s'", id)
	}

	// Event-driven path (in-process): race-free subscribe-then-snapshot.
	code, status := awaitSettle(id, time.Duration(timeout)*time.Second)
	switch code {
	case 0:
		replyResolve(id)
		fmt.Printf("%s replied (%s):\n", id, status)
		cmdWire([]string{id, "-n", strconv.Itoa(n)})
		return
	case 3:
		fmt.Fprintf(os.Stderr, "%s is blocked (needs input). Inspect: cartel wire %s\n", id, id)
		os.Exit(3)
	case 4:
		fmt.Fprintf(os.Stderr, "%s exited before replying\n", id)
		os.Exit(4)
	case 2:
		fmt.Fprintf(os.Stderr, "%s still working after %ds (raise --timeout)\n", id, timeout)
		os.Exit(2)
	}

	// Setup failure (code 5): polling fallback.
	deadline := time.Now().Add(time.Duration(timeout) * time.Second)
	time.Sleep(time.Second)
	for {
		switch st := agentStatus(id); st {
		case "idle", "done":
			replyResolve(id)
			fmt.Printf("%s replied (%s):\n", id, st)
			cmdWire([]string{id, "-n", strconv.Itoa(n)})
			return
		case "blocked":
			fmt.Fprintf(os.Stderr, "%s is blocked (needs input). Inspect: cartel wire %s\n", id, id)
			os.Exit(3)
		case "exited":
			fmt.Fprintf(os.Stderr, "%s exited before replying\n", id)
			os.Exit(4)
		}
		if time.Now().After(deadline) {
			fmt.Fprintf(os.Stderr, "%s still working after %ds (raise --timeout)\n", id, timeout)
			os.Exit(2)
		}
		time.Sleep(time.Second)
	}
}

// ---------------------------------------------------------------------------
// bury (fail-closed teardown)
// ---------------------------------------------------------------------------

func cmdBury(args []string) {
	if len(args) == 0 {
		die("bury: missing <id>")
	}
	id := args[0]
	force := len(args) > 1 && args[1] == "--force"
	s, err := readSicario(id)
	if err != nil {
		die("unknown sicario '%s'", id)
	}
	checkout := ""
	if s.Checkout != nil {
		checkout = *s.Checkout
	}
	branch := ""
	if s.Branch != nil {
		branch = *s.Branch
	}
	container := s.Container
	if container == "" {
		container = "workspace"
	}

	// Fail-closed: never tear down unlanded work without --force.
	if s.Worktree && !force {
		if checkout != "" && isDir(checkout) && worktreeDirty(checkout) {
			die("sicario '%s' has uncommitted changes in its worktree. Commit them, or discard with: cartel bury %s --force", id, id)
		}
		if branch != "" && branchHasUnpushed(s.Cwd, branch) {
			die("sicario '%s' branch '%s' has commits on no remote. Push them, or discard with: cartel bury %s --force", id, branch, id)
		}
	}

	if !lockAcquire(20 * time.Second) {
		die("busy: another cartel operation holds the lock (%s)", lockDir)
	}
	lockHeld := true
	defer func() {
		if lockHeld {
			lockRelease()
		}
	}()

	switch {
	case container == "tab":
		// Quiesce the agent BEFORE touching the worktree: closing the tab stops the
		// sicario process so it can't write more files during teardown.
		if !herdrOK("tab", "close", s.TabID) {
			fmt.Fprintf(os.Stderr, "cartel: warning: tab close failed for %s\n", id)
		}
		if s.Worktree && checkout != "" && isDir(checkout) {
			if force {
				gitOK(s.Cwd, "worktree", "remove", "--force", checkout)
			} else {
				// TOCTOU re-check now the agent is stopped, then remove WITHOUT --force.
				if worktreeDirty(checkout) || (branch != "" && branchHasUnpushed(s.Cwd, branch)) {
					die("sicario '%s' has unlanded work (detected after stopping it). Land it, or discard with: cartel bury %s --force  [worktree kept at: %s]", id, id, checkout)
				}
				if !gitOK(s.Cwd, "worktree", "remove", checkout) {
					die("git refused to remove worktree for '%s' (uncommitted changes). Land it, or: cartel bury %s --force  [worktree kept at: %s]", id, id, checkout)
				}
			}
			if !isDir(checkout) {
				_ = os.Remove(filepath.Dir(checkout))
			}
		}
	case s.Worktree:
		if force {
			herdrOK("worktree", "remove", "--workspace", s.WorkspaceID, "--force")
			if checkout != "" && isDir(checkout) {
				gitOK(s.Cwd, "worktree", "remove", "--force", checkout)
			}
		} else {
			if checkout != "" && isDir(checkout) && (worktreeDirty(checkout) || (branch != "" && branchHasUnpushed(s.Cwd, branch))) {
				die("sicario '%s' has unlanded work. Land it, or discard with: cartel bury %s --force  [worktree kept at: %s]", id, id, checkout)
			}
			herdrOK("worktree", "remove", "--workspace", s.WorkspaceID)
			if checkout != "" && isDir(checkout) {
				gitOK(s.Cwd, "worktree", "remove", checkout)
			}
		}
	default:
		if !herdrOK("workspace", "close", s.WorkspaceID) {
			fmt.Fprintf(os.Stderr, "cartel: warning: workspace close failed for %s\n", id)
		}
	}
	_ = os.Remove(stateFile(id))
	replyClear(id)
	lockRelease()
	lockHeld = false

	if s.Worktree && branch != "" {
		if force {
			gitOK(s.Cwd, "branch", "-D", branch)
			fmt.Printf("buried %s (branch %s discarded)\n", id, branch)
		} else {
			fmt.Printf("buried %s (branch %s kept: git -C %s branch -D %s to remove)\n", id, branch, s.Cwd, branch)
		}
	} else {
		fmt.Printf("buried %s\n", id)
	}
	if fileExists(reportFile(id)) {
		fmt.Printf("  report retained: cartel report %s\n", id)
	}
}
