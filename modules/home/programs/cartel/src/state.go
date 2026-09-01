package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"syscall"
	"time"
)

// Sicario is the persisted record for one recruited worker. The on-disk shape is
// kept byte-compatible with the previous bash implementation so state written by
// either is readable by the other during migration.
type Sicario struct {
	ID          string  `json:"id"`
	Kind        string  `json:"kind"`
	Exec        string  `json:"exec"`
	Cwd         string  `json:"cwd"`
	AgentCwd    string  `json:"agent_cwd"`
	Container   string  `json:"container"`
	WorkspaceID string  `json:"workspace_id"`
	TabID       string  `json:"tab_id"`
	PaneID      string  `json:"pane_id"`
	Worktree    bool    `json:"worktree"`
	Branch      *string `json:"branch"`
	Checkout    *string `json:"checkout"`
	Brief       string  `json:"brief"`
	Created     string  `json:"created"`
}

func readSicario(id string) (*Sicario, error) {
	b, err := os.ReadFile(stateFile(id))
	if err != nil {
		return nil, err
	}
	var s Sicario
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

// writeAtomic writes v as JSON to path via a same-dir temp + rename, 0600.
func writeAtomic(path string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	_ = tmp.Chmod(0o600)
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

func writeSicario(s *Sicario) error { return writeAtomic(stateFile(s.ID), s) }

// listSicarios returns every persisted sicario, sorted by id.
func listSicarios() []*Sicario {
	files, _ := filepath.Glob(filepath.Join(stateDir, "*.json"))
	out := make([]*Sicario, 0, len(files))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var s Sicario
		if json.Unmarshal(b, &s) != nil || s.ID == "" {
			continue
		}
		out = append(out, &s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// paneToID maps every recorded sicario pane_id -> id (used by the event stream).
func paneToID() map[string]string {
	m := map[string]string{}
	for _, s := range listSicarios() {
		if s.PaneID != "" {
			m[s.PaneID] = s.ID
		}
	}
	return m
}

// --- Reply correlation: a "pending" record means we sent an order/brief and are
// waiting for the sicario to complete a turn. Resolved (by await/daemon) when it
// next settles to idle/done - i.e. it actually responded. ---

type Reply struct {
	Corr      string  `json:"corr"`
	SentAt    string  `json:"sent_at"`
	Message   string  `json:"message"`
	State     string  `json:"state"`
	RepliedAt *string `json:"replied_at"`
}

func replyOpen(id, msg string) error {
	return writeAtomic(replyFile(id), Reply{
		Corr: corrID(), SentAt: nowUTC(), Message: msg, State: "pending",
	})
}

// replyResolve flips a pending record to replied; returns true iff it did.
func replyResolve(id string) bool {
	b, err := os.ReadFile(replyFile(id))
	if err != nil {
		return false
	}
	var r Reply
	if json.Unmarshal(b, &r) != nil || r.State != "pending" {
		return false
	}
	t := nowUTC()
	r.State = "replied"
	r.RepliedAt = &t
	return writeAtomic(replyFile(id), r) == nil
}

func replyState(id string) string {
	b, err := os.ReadFile(replyFile(id))
	if err != nil {
		return "none"
	}
	var r Reply
	if json.Unmarshal(b, &r) != nil || r.State == "" {
		return "none"
	}
	return r.State
}

func replyClear(id string) { _ = os.Remove(replyFile(id)) }

// --- Concurrency lock (portable: macOS has no flock; mkdir is atomic). Serializes
// the herdr-mutation + state-write sections of recruit/bury so parallel calls
// never interleave container/pane operations or clobber each other's state. ---

func lockAcquire(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		if err := os.Mkdir(lockDir, 0o700); err == nil {
			_ = os.WriteFile(filepath.Join(lockDir, "pid"), []byte(strconv.Itoa(os.Getpid())), 0o600)
			return true
		}
		// Steal a lock whose holder is dead.
		if b, err := os.ReadFile(filepath.Join(lockDir, "pid")); err == nil {
			if pid, err := strconv.Atoi(string(b)); err == nil && pid > 0 {
				if syscall.Kill(pid, 0) != nil {
					_ = os.RemoveAll(lockDir)
					continue
				}
			}
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func lockRelease() { _ = os.RemoveAll(lockDir) }
