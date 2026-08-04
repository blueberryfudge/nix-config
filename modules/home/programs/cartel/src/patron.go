package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ---------------------------------------------------------------------------
// patron - seat the orchestrator you talk to
// ---------------------------------------------------------------------------

func cmdPatron(args []string) {
	kind := "claude"
	target, _ := os.Getwd()
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--kind":
			kind = next(args, &i)
		case "--cwd", "--target":
			target = next(args, &i)
		default:
			die("patron: unknown option '%s'", args[i])
		}
	}
	caphome := filepath.Join(cartelHome, "patron")
	capFile := filepath.Join(caphome, "AGENTS.md")
	instrB, err := os.ReadFile(capFile)
	if err != nil {
		die("patron instructions not found: %s", capFile)
	}
	if !isDir(target) {
		die("target repo not a directory: %s", target)
	}
	if abs, err := filepath.Abs(target); err == nil {
		target = abs
	}
	instr := string(instrB)

	// The patrón works ON $target but RUNS FROM its own home so AGENTS.md /
	// CLAUDE.md load as strong PROJECT memory (a bare --append-system-prompt is too
	// weak to override global "just execute" defaults). Materialize the
	// instructions as REAL files in a writable run dir: when installed via
	// home-manager the source is a /nix/store symlink, and claude refuses to import
	// an AGENTS.md that resolves outside the workspace.
	rundir := patronRun
	_ = os.MkdirAll(rundir, 0o755)
	_ = os.WriteFile(filepath.Join(rundir, "AGENTS.md"), instrB, 0o644)
	_ = os.WriteFile(filepath.Join(rundir, "CLAUDE.md"), []byte("@AGENTS.md\n"), 0o644)
	_ = os.Setenv("CARTEL_TARGET", target)
	if err := os.Chdir(rundir); err != nil {
		die("patron: cannot enter run dir %s: %v", rundir, err)
	}
	fmt.Fprintf(os.Stderr, "seating the patrón (%s); target repo: %s\n", kind, target)

	// Register this pane with the (on-demand) daemon so settled sicarios are
	// reported straight into this chat, composer-safely. Replaces the old per-pane
	// background lookout entirely. Requires running inside Herdr (HERDR_PANE_ID).
	if pane := os.Getenv("HERDR_PANE_ID"); pane != "" {
		daemonRegister(pane)
	}

	switch kind {
	case "claude":
		// Auto-approve ONLY the `cartel` command (scoped, not a blanket skip); the
		// instructions ride the invisible system prompt + CLAUDE.md.
		execAgent("claude",
			"--add-dir", target,
			"--allowedTools", "Bash(cartel:*),Bash(cartel *)",
			"--append-system-prompt", instr)
	case "pi":
		execAgent("pi", "-a", "--append-system-prompt", instr)
	case "cursor":
		// cursor-agent has no system-prompt flag, so load the brief as an always-on
		// PROJECT RULE (silent), scoped to this run dir only. We deliberately do NOT
		// touch the global cli-config: adding Shell(cartel) there would let EVERY
		// future Cursor session spawn autonomous sicarios without approval.
		rulesDir := filepath.Join(rundir, ".cursor", "rules")
		_ = os.MkdirAll(rulesDir, 0o755)
		rule := "---\ndescription: patrón orchestrator\nalwaysApply: true\n---\n\n" +
			fmt.Sprintf("Your target repo is %s (also in $CARTEL_TARGET).\n\n", target) + instr
		_ = os.WriteFile(filepath.Join(rulesDir, "patron.mdc"), []byte(rule), 0o644)
		fmt.Fprintln(os.Stderr, "note: Cursor will ask before each `cartel` command. To skip that permanently")
		fmt.Fprintln(os.Stderr, "      (broadens ALL Cursor sessions), add \"Shell(cartel)\" under permissions.allow")
		fmt.Fprintln(os.Stderr, "      in ~/.cursor/cli-config.json yourself.")
		execAgent("cursor-agent", "--trust")
	default:
		die("patron: unsupported --kind '%s' (cursor|claude|pi)", kind)
	}
}

// execAgent replaces the current process with the agent CLI (like bash `exec`),
// so the patrón owns the terminal directly.
func execAgent(name string, args ...string) {
	path, err := exec.LookPath(name)
	if err != nil {
		die("executable '%s' not found on PATH", name)
	}
	argv := append([]string{path}, args...)
	if err := syscall.Exec(path, argv, os.Environ()); err != nil {
		die("exec %s failed: %v", name, err)
	}
}

// ---------------------------------------------------------------------------
// lookout - foreground, human-facing watcher (auto-reporting is the daemon's job)
// ---------------------------------------------------------------------------

func cmdLookout(args []string) {
	interval := 5
	states := "blocked done exited"
	notifyAgent := ""
	bell := true
	poll := false
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--interval":
			v, err := strconv.Atoi(next(args, &i))
			if err != nil {
				die("lookout: --interval must be an integer")
			}
			interval = v
		case "--on":
			states = strings.ReplaceAll(next(args, &i), ",", " ")
		case "--notify-agent":
			notifyAgent = next(args, &i)
		case "--notify-pane":
			next(args, &i) // accepted but IGNORED: composer-safe reporting is the daemon's job now
		case "--no-bell":
			bell = false
		case "--poll":
			poll = true
		default:
			die("lookout: unknown option '%s'", args[i])
		}
	}
	stateSet := map[string]bool{}
	for _, s := range strings.Fields(states) {
		stateSet[s] = true
	}

	prev := map[string]string{}
	reported := map[string]bool{}

	notify := func(id, st string) {
		body, sound := st, "none"
		switch st {
		case "blocked":
			body, sound = "needs input", "request"
		case "done", "idle":
			body, sound = "finished", "done"
		case "exited":
			body, sound = "process exited", "request"
		case "replied":
			body, sound = "responded to your order", "done"
		}
		line := fmt.Sprintf("%s  %s -> %s (%s)", time.Now().Format("15:04:05"), id, st, body)
		if bell {
			fmt.Print(line + "\a\n")
		} else {
			fmt.Println(line)
		}
		appendFile(watchLog, line+"\n")
		herdrOK("notification", "show", "cartel: "+id+" "+st, "--body", body, "--sound", sound)
		if notifyAgent != "" {
			nudgeAgent(notifyAgent, fmt.Sprintf("[cartel] sicario '%s' -> %s (%s). Run: cartel wire %s  then handle or report it.", id, st, body, id))
		}
	}

	handle := func(id, st string) {
		if old, ok := prev[id]; ok && old == st {
			return
		}
		prev[id] = st
		if st == "working" {
			reported[id] = false
		}
		if st == "idle" || st == "done" {
			if replyResolve(id) {
				notify(id, "replied")
			}
		}
		if !stateSet[st] {
			return
		}
		if reported[id] {
			return
		}
		reported[id] = true
		notify(id, st)
	}

	// Baseline: pre-mark anything already settled so we don't alert on old results.
	for _, s := range listSicarios() {
		st := agentStatus(s.ID)
		prev[s.ID] = st
		if stateSet[st] {
			reported[s.ID] = true
		}
	}

	extra := ""
	if notifyAgent != "" {
		extra += ", nudge=" + notifyAgent
	}
	if bell {
		extra += ", bell on"
	}
	fmt.Printf("cartel lookout: alert on [%s]%s. Ctrl-C to stop.\n", states, extra)

	ctx, cancel := context.WithCancel(context.Background())
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sig; fmt.Print("\ncartel lookout stopped\n"); cancel() }()

	if poll {
		fmt.Printf("cartel lookout: polling every %ds.\n", interval)
		t := time.NewTicker(time.Duration(interval) * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				for _, s := range listSicarios() {
					handle(s.ID, agentStatus(s.ID))
				}
			}
		}
	}

	fmt.Println("cartel lookout: event stream live (instant).")
	streamTransitions(ctx, handle)
}

func appendFile(path, s string) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(s)
}

// ---------------------------------------------------------------------------
// usage
// ---------------------------------------------------------------------------

func usage() {
	fmt.Print(`cartel - talk to your patrón, run a crew of sicarios (Herdr + git worktrees)

USAGE
  cartel                                                    # seat the patrón here (= cartel patron)
  cartel patron [--kind <claude|pi|cursor>] [--cwd <repo>]  # seat the patrón (default: cwd)
  cartel recruit <id> --kind <cursor|claude> [options] [-- <extra agent args>]
  cartel roster [--json]
  cartel status [<id>] [--json]
  cartel wire <id> [-n <lines>]
  cartel order <id> <text...>
  cartel await <id> [--timeout <s>] [-n <lines>]   # block until it replies, print reply
  cartel key <id> <key...>           # e.g. enter | down enter | ctrl+c
  cartel wait <id> [--status idle|working|blocked|unknown] [--timeout <ms>]
  cartel focus <id>
  cartel bury <id> [--force]         # (alias: silence) fail-closed on unlanded work
  cartel lookout [--interval <s>] [--on <states>] [--notify-agent <name>] [--no-bell] [--poll]
  cartel help

  plain aliases still work: up=recruit  down=bury  say=order  log=wire  ls=roster  watch=lookout

recruit OPTIONS
  --kind K            cursor | claude                             (required)
                      (pi is refused for sicarios: it has no shell-guard hook)
  --exec CMD          override the executable for --kind; must be a BARE command
                      name on the allowlist (cursor-agent|claude|pi, or a name in
                      $CARTEL_EXEC_ALLOW) - never a path
  --cwd PATH          working dir for the sicario  (default: $CARTEL_TARGET or cwd)
  --tab               recruit as a TOP TAB in the current workspace
  --workspace         recruit as its own left-sidebar space        (default)
  --worktree          isolate in a git worktree+branch  (branch: cartel/<id>)
  --brief TEXT        opening task prompt sent to the agent
  --brief-file PATH   read the opening prompt from a file
  -- <args>           everything after -- is passed to the agent CLI

kind -> executable:  cursor=cursor-agent  claude=claude  pi=pi

lookout OPTIONS
  --interval S        poll seconds for the fallback path            (default: 5)
  --on STATES         states to alert on, comma/space separated
                                              (default: blocked,done,exited)
  --notify-agent NAME nudge this patrón agent on each alert (opt-in)
  --no-bell           don't ring the terminal bell on an alert
  --poll              force polling even if the event stream is available

NOTES
  * Auto-reporting to the patrón is handled by a single on-demand daemon
    (cartel daemon), started automatically by 'cartel patron'. It reports a
    settled sicario straight into the patrón's chat, but is COMPOSER-SAFE: it
    only injects when your prompt line is empty and DEFERS while you are typing,
    retrying the instant you pause. It exits itself once no patrón panes remain.
  * cartel patron steers ANY repo (--cwd, default: current) but RUNS FROM its own
    home so AGENTS.md/CLAUDE.md load as strong project memory. The target repo is
    exported as $CARTEL_TARGET (sicario default --cwd).
  * Container: sicarios default to their own workspace; use --tab to place them as
    top tabs in your current workspace. Set CARTEL_DEFAULT_CONTAINER=tab to default.
  * State + config live under $CARTEL_HOME (~/cartel). Nothing is written to your
    repo unless you pass --worktree. Run inside your Herdr session to target it.
`)
}
