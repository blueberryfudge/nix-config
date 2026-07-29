#!/usr/bin/env bash
# cartel - talk to your patrón, run a crew of sicarios (minimal orchestrator).
#
# A tiny wrapper around Herdr's CLI/socket API (verified against Herdr 0.7.3).
# Your primary agent (the patrón, the one you chat with) delegates work by
# calling `cartel recruit ...`, which:
#   1. opens a new Herdr tab/workspace (optionally an isolated git worktree),
#   2. starts an independent coding-agent CLI (cursor/claude/pi) inside it, and
#   3. hands it a brief as its opening prompt.
# You then observe/steer sicarios with `cartel status|wire|order|key|wait`, and
# retire them with `cartel bury`. No harness sub-agent magic - just Herdr + git.
#
# Self-contained: this script and all state live under $CARTEL_HOME (~/cartel by
# default). It never writes into the directory you run it from, and only touches
# a target git repo when you pass --worktree (which creates a branch+worktree).
#
# Verbs are themed; the plain originals still work as aliases:
#   recruit=up  bury=down(silence)  order=say  wire=log  patron=captain
#   roster=ls   lookout=watch
#
# Requires: herdr (running session), jq, and the agent CLIs you launch.
set -euo pipefail

CARTEL_HOME="${CARTEL_HOME:-$HOME/cartel}"
STATE_DIR="$CARTEL_HOME/state"
REPLY_DIR="$STATE_DIR/replies"
# Durable queue of sicario transitions awaiting an in-chat report to the patrón.
# Events land here the instant they happen; delivery into the patrón's pane is
# deferred (see report_try_deliver) until the Don's composer is empty, so a
# report is NEVER typed over input you are mid-way through writing.
REPORT_QUEUE="$STATE_DIR/.report-queue"
mkdir -p "$STATE_DIR" "$REPLY_DIR"
# Keep cartel state owner-only: it feeds the patrón's TRUSTED report channel, so
# it must not be a world-writable injection surface. (Defense-in-depth only - a
# same-UID sicario can still reach it, which is why the report nudge is also
# content-sanitised in report_try_deliver.)
chmod 700 "$STATE_DIR" "$REPLY_DIR" 2>/dev/null || true

herdr() { command herdr "$@"; }
die() { printf 'cartel: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need herdr; need jq

# Pin EVERY herdr call (and cartel-events) to ONE explicit server via its control
# socket, resolved once. cartel mutates and DESTROYS containers, so silently
# reaching a different server when several run is dangerous. The herdr CLI honours
# HERDR_SOCKET_PATH (verified: a bogus value makes it fail), so:
#   - inside a herdr pane the inherited socket already targets the right server -
#     the common case, kept as-is with zero extra work;
#   - run OUTSIDE herdr (no socket inherited) we look up the default session's
#     socket and export it, instead of letting the CLI pick an ambient default.
# Exporting (not a --session flag) also means it can never leak into an
# `agent start ... -- <agent argv>` passthrough, and cartel-events inherits it.
if [ -z "${HERDR_SOCKET_PATH:-}" ]; then
  _cartel_sock=$(command herdr session list --json 2>/dev/null \
    | jq -r '(.sessions[]? | select(.default==true) | .socket_path) // (.sessions[]? | .socket_path) // empty' 2>/dev/null \
    | head -1) || true
  if [ -n "${_cartel_sock:-}" ]; then export HERDR_SOCKET_PATH="$_cartel_sock"; fi
  unset _cartel_sock 2>/dev/null || true
fi

state_file() { printf '%s/%s.json' "$STATE_DIR" "$1"; }
reply_file() { printf '%s/%s.json' "$REPLY_DIR" "$1"; }

# Resolve the event-stream binary (env override, then PATH, then the built-in
# path). Prints the path iff it exists and is executable, else nothing. Used by
# both `lookout` (streaming) and `await` (one-shot).
events_bin() {
  local b="${CARTEL_EVENTS_BIN:-}"
  [ -n "$b" ] || b=$(command -v cartel-events 2>/dev/null || true)
  [ -n "$b" ] || b="$CARTEL_HOME/bin/cartel-events"
  # Must not fail under `set -e`: an absent/non-exec binary means "no event
  # backend" (callers fall back to polling), not a fatal error.
  [ -x "$b" ] && printf '%s' "$b"
  return 0
}
valid_id() { case "$1" in [a-z][a-z0-9_-]*) [ "${#1}" -le 32 ] ;; *) return 1 ;; esac; }

# --- Concurrency lock (portable: macOS has no flock; mkdir is atomic). Serializes
# the herdr-mutation + state-write sections of recruit/bury so parallel calls
# never interleave container/pane operations or clobber each other's state. ---
CARTEL_LOCK="$CARTEL_HOME/.lock.d"
lock_acquire() {  # <timeout_s>
  local t=${1:-20} waited=0 pid
  while ! mkdir "$CARTEL_LOCK" 2>/dev/null; do
    pid=$(cat "$CARTEL_LOCK/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$CARTEL_LOCK" 2>/dev/null || true; continue   # holder is dead: steal it
    fi
    waited=$((waited+1)); [ "$waited" -ge $((t*10)) ] && return 1
    sleep 0.1
  done
  printf '%s' "$$" > "$CARTEL_LOCK/pid" 2>/dev/null || true
  return 0
}
lock_release() { rm -rf "$CARTEL_LOCK" 2>/dev/null || true; }

# --- Reply correlation: a "pending" record means we sent an order/brief and are
# waiting for the sicario to complete a turn. Resolved (by `await` or `lookout`)
# when it next settles to idle/done - i.e. it actually responded. ---
reply_open() {  # <id> <message>
  local id=$1 msg=$2 corr tmp
  corr=$(uuidgen 2>/dev/null || printf '%s-%s' "$(date +%s)" "$$")
  tmp=$(mktemp "${REPLY_DIR}/.tmp.${id}.XXXXXX") || return 1
  jq -n --arg corr "$corr" --arg sent "$(date -u +%FT%TZ)" --arg msg "$msg" \
     '{corr:$corr, sent_at:$sent, message:$msg, state:"pending", replied_at:null}' > "$tmp" \
     && mv -f "$tmp" "$(reply_file "$id")"
}
reply_resolve() {  # <id> -> 0 if it flipped a pending record to replied, else 1
  local id=$1 f tmp; f=$(reply_file "$id"); [ -f "$f" ] || return 1
  [ "$(jq -r '.state' "$f" 2>/dev/null)" = pending ] || return 1
  tmp=$(mktemp "${REPLY_DIR}/.tmp.${id}.XXXXXX") || return 1
  jq --arg t "$(date -u +%FT%TZ)" '.state="replied" | .replied_at=$t' "$f" > "$tmp" && mv -f "$tmp" "$f"
}
reply_clear() { rm -f "$(reply_file "$1")" 2>/dev/null || true; }

# --- Fail-closed teardown guards: never bury unlanded work without --force. ---
worktree_dirty() { [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }
branch_has_unpushed() {  # <repo_cwd> <branch> -> 0 if branch has commits on no remote
  local cwd=$1 br=$2 n
  git -C "$cwd" show-ref --verify --quiet "refs/heads/$br" || return 1
  [ -n "$(git -C "$cwd" remote 2>/dev/null)" ] || return 1   # no remote: nothing to push to
  n=$(git -C "$cwd" rev-list --count "$br" --not --remotes 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ]
}

# The Herdr workspace to host tab-mode sicarios: the pane's own workspace when
# cartel runs inside Herdr, else the focused workspace.
resolve_target_ws() {
  if [ -n "${HERDR_WORKSPACE_ID:-}" ]; then printf '%s' "$HERDR_WORKSPACE_ID"; return 0; fi
  local w; w=$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]? | select(.focused==true) | .workspace_id' | head -1)
  [ -n "$w" ] && printf '%s' "$w"
}

# Tear down a just-created container after a failed launch (or on `bury`), so we
# never orphan a workspace, tab, worktree checkout, or branch.
destroy_container() {  # <container> <worktree:0|1> <wsid> <tabid> <repo_cwd> <checkout> <id>
  local c=$1 wt=$2 wsid=$3 tabid=$4 cwd=$5 checkout=$6 id=$7
  if [ "$c" = tab ]; then
    [ -z "$tabid" ] || herdr tab close "$tabid" >/dev/null 2>&1 || true
    if [ "$wt" -eq 1 ] && [ -n "$checkout" ] && [ -d "$checkout" ]; then
      git -C "$cwd" worktree remove --force "$checkout" >/dev/null 2>&1 || true
      git -C "$cwd" branch -D "cartel/$id" >/dev/null 2>&1 || true
    fi
  elif [ "$wt" -eq 1 ]; then
    herdr worktree remove --workspace "$wsid" --force >/dev/null 2>&1 || true
    git -C "$cwd" branch -D "cartel/$id" >/dev/null 2>&1 || true
  else
    herdr workspace close "$wsid" >/dev/null 2>&1 || true
  fi
}

# Map a --kind to the interactive CLI executable Herdr should launch + detect.
kind_exec() {
  case "$1" in
    cursor) printf 'cursor-agent' ;;
    claude) printf 'claude' ;;
    pi)     printf 'pi' ;;
    *) return 1 ;;
  esac
}

# Resolve a sicario id to the herdr target we should address it by: its RECORDED
# pane id when we have state, else the raw argument. herdr does NOT keep agent
# names unique and rejects an ambiguous name with `agent_target_ambiguous`, so
# the pane id (unique, recorded at recruit time) is the reliable fast path. The
# raw fallback still serves the pre-recruit "is a live agent already named this?"
# probe (no state yet) and accepts a pane id passed in directly (a "<x>.json"
# state file never exists for a pane id, so it passes through unchanged).
agent_target() {  # <id-or-pane>
  local f pane
  f=$(state_file "$1")
  if [ -f "$f" ]; then
    pane=$(jq -r '.pane_id // empty' "$f" 2>/dev/null || true)
    [ -n "$pane" ] && { printf '%s' "$pane"; return 0; }
  fi
  printf '%s' "$1"
}

# Current Herdr agent state, or "exited" when the agent target is gone.
# One of: working | idle | done | blocked | unknown | exited
agent_status() {
  local out
  out=$(herdr agent get "$(agent_target "$1")" 2>/dev/null) || { printf 'exited'; return 0; }
  printf '%s' "$out" | jq -r '.result.agent.agent_status // "exited"' 2>/dev/null || printf 'exited'
}

# Wait until an agent has actually STARTED its turn (left idle) or gone. Used
# after launching a sicario with its brief as the initial prompt: it confirms the
# brief was picked up before we open the reply record, so `await` can't mistake a
# still-booting idle agent for a completed reply. Fast (returns the moment it
# moves), bounded at ~10s. `blocked` counts as started (e.g. a trust screen).
wait_started() {
  local id=$1 i st
  for i in $(seq 1 20); do
    st=$(agent_status "$id")
    case "$st" in working|done|blocked) return 0 ;; exited) return 2 ;; esac
    sleep 0.5
  done
  return 1
}

# Heuristic: is the sicario sitting on a first-run trust/login/onboarding
# screen? If so, a brief must not be auto-typed - the human answers first.
on_startup_gate() {
  local v
  v=$(herdr agent read "$(agent_target "$1")" --source visible --lines 40 2>/dev/null || true)
  printf '%s' "$v" | grep -Eiq 'trust this folder|do you trust|yes, i trust|select .*login|sign ?in|log ?in|authenticat|onboard|api key'
}

# Send a prompt to an agent and submit it. Herdr's `agent send` types the text
# but does NOT press Enter, and TUIs need the pasted text to settle before Enter
# registers (empirically ~1.5s for claude). Press Enter with settle, retrying
# until the agent actually leaves idle (extra Enter on an empty composer is a
# harmless no-op).
submit_prompt() {  # <id> <agent_pane_id> <text>
  herdr agent send "$(agent_target "$1")" "$3" >/dev/null || return 1
  local i
  for i in 1 2 3 4; do
    sleep 1.2
    herdr pane send-keys "$2" enter >/dev/null 2>&1 || return 1
    sleep 0.8
    case "$(agent_status "$1")" in working|done|blocked) return 0 ;; esac
  done
  return 0
}

# Inject a message into an agent's session and submit it (used to "wake" the
# patrón). Best-effort; resolves the target's pane for the Enter.
nudge_agent() {  # <target> <text>
  local pane
  pane=$(herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.pane_id // empty') || return 0
  [ -n "$pane" ] || return 0
  herdr agent send "$1" "$2" >/dev/null 2>&1 || return 0
  sleep 1.2
  herdr pane send-keys "$pane" enter >/dev/null 2>&1 || true
}

# --- Composer-state guard (condensed from firstmate's herdr backend). Lets the
# patrón notifier push a result into the patrón's pane ONLY when your composer is
# empty, and defer while you are mid-typing - so a report is never typed over
# your in-progress prompt. herdr exposes no cursor-row primitive, so we read the
# pane's styled tail, DROP de-emphasised "ghost" suggestion text (claude/codex
# render a dim hint in the empty composer that a plain read can't tell from real
# input), find the bottom-most composer row, and classify empty|pending|unknown.
COMPOSER_LINES="${CARTEL_COMPOSER_LINES:-20}"
# Bare (unbordered) AGENT prompt glyphs only: ❯ (claude) and › (codex). An
# alternation of whole byte sequences, NOT a [❯›] bracket class: under LC_CTYPE=C
# a bracket class matches individual UTF-8 bytes and would spuriously match other
# multibyte glyphs (e.g. box-drawing corners) via the shared leading byte.
COMPOSER_BARE_RE='^(❯|›)'
COMPOSER_IDLE_RE='^Type a message\.\.\.$'   # known empty-composer placeholder

# Drop every CSI escape, leaving plain text (structural row detection: ghost text
# is KEPT so a border/prompt glyph stays visible). ':' in the class strips a whole
# ITU colon-form SGR (38:2::r:g:b) rather than leaving a dangling tail.
composer_strip_ansi() { LC_ALL=C sed "s/$(printf '\033')\\[[0-9;:?]*[[:alpha:]]//g"; }

# Extract "real typed content" from a styled composer row: drop dim/faint runs
# (SGR 2 - claude/codex ghost/suggestion text) and dark/muted TRUECOLOR
# foreground runs (grok placeholder), keep normal-intensity real input. Assumes a
# dark terminal theme (real input is bright; only UI hints are dark). Reads the
# styled line on stdin, prints plain non-ghost text.
composer_strip_ghost() {
  LC_ALL=C awk -v lumamax="${CARTEL_COMPOSER_GHOST_LUMA_MAX:-128}" '
    function sgr_code(v, b) { b=v; sub(/:.*/,"",b); if (b=="") b="0"; return b }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode=a[p+1]; code=sgr_code(mode)
      if (index(mode, ":") > 0) return p+1
      if (code=="5") return p+2
      if (code=="2") return p+4
      return p+1
    }
    function fg38_is_dark(a, p, k, lumamax,   spec, nf, f, r, g, b) {
      spec=a[p]
      if (index(spec, ":") > 0) {
        nf=split(spec, f, ":")
        if (f[2] != "2" || nf < 5) return 0
        r=f[nf-2]+0; g=f[nf-1]+0; b=f[nf]+0
        return ((299*r+587*g+114*b)/1000 < lumamax) ? 1 : 0
      }
      if (p+1 > k || a[p+1] != "2" || p+4 > k) return 0
      r=a[p+2]+0; g=a[p+3]+0; b=a[p+4]+0
      return ((299*r+587*g+114*b)/1000 < lumamax) ? 1 : 0
    }
    {
      line=$0; out=""; dim=0; darkfg=0; n=length(line); i=1
      while (i <= n) {
        c=substr(line, i, 1)
        if (c == "\033") {
          j=i+1
          if (substr(line, j, 1) == "[") {
            j++; params=""
            while (j <= n) { cc=substr(line, j, 1); if (cc ~ /[@-~]/) break; params=params cc; j++ }
            if (j <= n && substr(line, j, 1) == "m") {
              if (params == "") params="0"
              k=split(params, a, ";")
              for (p=1; p <= k; p++) {
                v=a[p]; code=sgr_code(v)
                if (code == "38") { darkfg=fg38_is_dark(a, p, k, lumamax); p=skip_color_payload(a, p, k) }
                else if (code == "48" || code == "58") p=skip_color_payload(a, p, k)
                else if (code == "2") dim=1
                else if (code == "0") { dim=0; darkfg=0 }
                else if (code == "22") dim=0
                else if (code == "39") darkfg=0
                else if (code+0 >= 30 && code+0 <= 37) darkfg=0
                else if (code+0 >= 90 && code+0 <= 97) darkfg=0
              }
            }
            if (j <= n) { i=j+1; continue }
          }
          i=i+1; continue
        }
        if (dim == 0 && darkfg == 0) out=out c
        i++
      }
      print out
    }
  '
}

# Verdict for one already-trimmed, border-stripped composer row.
composer_classify() {  # <bordered:0|1> <content>
  local bordered=$1 content=$2
  case "$content" in
    '❯'|'›') printf empty; return 0 ;;
    '>'|'$'|'%'|'#') { [ "$bordered" = 1 ] && printf empty || printf unknown; }; return 0 ;;
  esac
  [ -n "$content" ] || { printf empty; return 0; }
  printf '%s' "$content" | grep -qE "$COMPOSER_IDLE_RE" && { printf empty; return 0; }
  case "$content" in
    '❯ '*|'› '*|'> '*|'$ '*|'% '*|'# '*) content=${content#??} ;;
    '❯'*|'›'*|'>'*|'$'*|'%'*|'#'*) content=${content#?} ;;
  esac
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  [ -n "$content" ] || { printf empty; return 0; }
  printf '%s' "$content" | grep -qE "$COMPOSER_IDLE_RE" && { printf empty; return 0; }
  printf pending
}

# Classify a pane's composer as empty|pending|unknown. Keeps the LAST (bottom-most)
# matching row so a stale decorative box earlier in scrollback can't outrank the
# live composer. Falls back to 'unknown' (never a safe inject target) on any read
# failure or when no composer row is recognised.
composer_state() {  # <pane_id>
  local pane=$1 cap line trimmed raw_match="" shape="" stripped bordered=0 found=0 fetch
  # herdr's `pane read --lines N` returns EMPTY when N is below the pane's
  # viewport height (verified), so always fetch a generous floor and trim the
  # tail locally to COMPOSER_LINES - a small direct request would read blank and
  # misclassify the composer as unknown, deferring every report forever.
  fetch=$COMPOSER_LINES; [ "$fetch" -ge 200 ] || fetch=200
  cap=$(herdr pane read "$pane" --source recent --lines "$fetch" --format ansi 2>/dev/null | tail -n "$COMPOSER_LINES") \
    || { printf unknown; return 0; }
  [ -n "$cap" ] || { printf unknown; return 0; }
  while IFS= read -r line; do
    trimmed=$(printf '%s' "$line" | composer_strip_ansi)
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|') shape=bordered; raw_match=$line; found=1 ;;
      *) printf '%s' "$trimmed" | grep -qE "$COMPOSER_BARE_RE" && { shape=bare; raw_match=$line; found=1; } ;;
    esac
  done <<EOF
$cap
EOF
  [ "$found" -eq 1 ] || { printf unknown; return 0; }
  stripped=$(printf '%s\n' "$raw_match" | composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  if [ "$shape" = bordered ]; then
    bordered=1
    stripped=${stripped//│/}; stripped=${stripped//┃/}; stripped=${stripped//|/}
    stripped="${stripped#"${stripped%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
  fi
  composer_classify "$bordered" "$stripped"
}

# Queue a settled-sicario transition for an eventual in-chat report.
report_enqueue() {  # <id> <state>
  ( umask 077; printf '%s\t%s\n' "$1" "$2" >> "$REPORT_QUEUE" ) 2>/dev/null || true
  chmod 600 "$REPORT_QUEUE" 2>/dev/null || true
}

# Deliver queued reports into the patrón's pane, but ONLY when the composer is
# empty (you are not typing). If you are mid-typing (pending) or the pane can't
# be classified (unknown), leave the queue untouched and return - the drain
# ticker retries the instant you pause, so nothing is ever typed over your input.
# Delivery is coalesced into ONE trigger (the patrón reconciles specifics via
# `cartel roster`), and confirmed by the composer clearing before the queue is
# cleared; an unconfirmed send is re-queued for the next attempt.
report_try_deliver() {  # <pane>
  local pane=$1 inflight msg i
  [ -s "$REPORT_QUEUE" ] || return 0
  herdr pane get "$pane" >/dev/null 2>&1 || return 0
  [ "$(composer_state "$pane")" = empty ] || return 0
  inflight=$(mktemp "$REPORT_QUEUE.inflight.XXXXXX" 2>/dev/null) || return 0
  mv "$REPORT_QUEUE" "$inflight" 2>/dev/null || { rm -f "$inflight"; return 0; }   # atomic claim; loser bails
  # SECURITY: this message is typed into the patrón's pane, where it is treated as
  # a trusted system directive - so it must carry NO sicario-controlled free text.
  # Only ids that pass valid_id ([a-z][a-z0-9_-], <=32) survive; a tampered/forged
  # queue line (a sicario runs as the same UID and can append to the queue) cannot
  # smuggle prose, newlines, or instructions through. The marker is a FIXED, terse
  # token - the patrón knows from AGENTS.md what to do on a `[cartel] settled:`
  # line, and reconciles the REAL set from `cartel roster` regardless - so we keep
  # the injected chat line short instead of restating the whole procedure.
  local raw_ids one ids=""
  raw_ids=$(cut -f1 "$inflight" 2>/dev/null | sort -u)
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    valid_id "$one" || continue
    ids="${ids:+$ids,}$one"
  done <<EOF
$raw_ids
EOF
  msg="[cartel] settled${ids:+: $ids}"
  if ! herdr pane send-text "$pane" "$msg" >/dev/null 2>&1; then
    cat "$inflight" >> "$REPORT_QUEUE" 2>/dev/null || true; rm -f "$inflight"; return 0
  fi
  sleep 1.2   # let the pasted text settle before Enter (TUIs swallow a too-fast Enter)
  for i in 1 2 3; do
    herdr pane send-keys "$pane" enter >/dev/null 2>&1 || true
    sleep 0.8
    if [ "$(composer_state "$pane")" != pending ]; then rm -f "$inflight"; return 0; fi
  done
  cat "$inflight" >> "$REPORT_QUEUE" 2>/dev/null || true; rm -f "$inflight"   # unconfirmed: retry later
  return 0
}

usage() {
  cat <<EOF
cartel - talk to your patrón, run a crew of sicarios (Herdr + git worktrees)

USAGE
  cartel                                                    # seat the patrón here (= cartel patron)
  cartel patron [--kind <claude|pi|cursor>] [--cwd <repo>]  # seat the patrón (default: cwd)
  cartel recruit <id> --kind <cursor|claude> [options] [-- <extra agent args>]
  cartel roster
  cartel status [<id>] [--json]
  cartel roster [--json]
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
                      \$CARTEL_EXEC_ALLOW) - never a path, so it can't launch an
                      unguarded process as a sicario
  --cwd PATH          working dir for the sicario  (default: \$CARTEL_TARGET or cwd)
  --tab               recruit as a TOP TAB in the current workspace
  --workspace         recruit as its own left-sidebar space        (default)
                      default is \$CARTEL_DEFAULT_CONTAINER or "workspace"
  --worktree          isolate in a git worktree+branch  (branch: cartel/<id>)
  --brief TEXT        opening task prompt sent to the agent
  --brief-file PATH   read the opening prompt from a file
  -- <args>           everything after -- is passed to the agent CLI

kind -> executable:  cursor=cursor-agent  claude=claude  pi=pi

EXAMPLES
  cartel recruit nixtweak --kind claude --worktree \\
        --brief "in modules/home/programs add a herdr config.toml via home-manager"
  cartel recruit scout --kind cursor --brief "map how backends are selected" -- --plan
  cartel status
  cartel wire nixtweak -n 120
  cartel order nixtweak "also add a regression test"
  cartel key nixtweak down enter     # answer a blocked approval / first-run prompt
  cartel bury nixtweak --force

lookout OPTIONS
  --interval S        poll seconds for the fallback path            (default: 5)
  --on STATES         states to alert on, comma/space separated
                                              (default: blocked,done,exited)
  --notify-agent NAME nudge this patrón agent on each alert (opt-in; injects
                      a message into its session - see caveat below)
  --no-bell           don't ring the terminal bell on an alert
  --poll              force polling even if the event binary is present

  By default lookout uses the event-driven Go source ($CARTEL_HOME/bin/cartel-events,
  build with: cd $CARTEL_HOME/events && go build -o ../bin/cartel-events .) for
  instant, near-zero-cost reactions, and falls back to polling if it is missing
  or the herdr socket drops. It also fires a "replied" alert when a sicario
  settles after an order/brief (reply correlation).

NOTES
  * Container: sicarios default to their own workspace (left sidebar "spaces").
    Use --tab to place them as top tabs in your current workspace instead.
    Set CARTEL_DEFAULT_CONTAINER=tab to make that the default.
    --tab needs a target workspace: your pane's own when run inside Herdr, else
    the focused one. --tab + --worktree makes the git worktree under
    ~/cartel/worktrees/<repo>/<id> and opens it as the tab.
  * cartel patron steers ANY repo (--cwd, default: current) but RUNS FROM its
    own home (~/cartel/patron) so AGENTS.md/CLAUDE.md load as strong project
    memory - a bare system-prompt is too weak to override global "just execute"
    defaults, which makes an in-repo patrón do the work itself. The target repo
    is exported as \$CARTEL_TARGET (sicario default --cwd) and passed via
    --add-dir for claude; sicario --tab recruits land in your current workspace
    since HERDR_WORKSPACE_ID is inherited from the launching tab.
  * On first launch in a new folder, agents may show a trust/login prompt.
    cartel detects this and skips the auto-brief; answer it (cartel focus <id>,
    or cartel key <id> enter), then send the task with: cartel order <id> "...".
  * cartel lookout prints each transition + rings the bell + fires a Herdr toast.
    Toasts only appear if you enable them in ~/.config/herdr/config.toml:
      [ui.toast]
      delivery = "herdr"
  * The patrón notifier (started automatically by 'cartel patron') reports a
    settled sicario straight into the patrón's chat, but is COMPOSER-SAFE: it
    only injects when your prompt line is empty and DEFERS while you are typing,
    retrying the instant you pause - so a report never lands on unsent input.
  * --notify-agent injects text+Enter into a NAMED agent's pane without that
    composer guard; if you are mid-typing in that pane it can disturb your input.
    Use it when the target is running unattended.
  * State + this script live under: $CARTEL_HOME  (nothing is written to your
    repo unless you pass --worktree). Run inside your Herdr session to target it.
EOF
}

cmd_up() {
  # Default --cwd to the patrón's target repo when set (CARTEL_TARGET), so the
  # patrón can run `cartel recruit ...` BARE - no `--cwd "$CARTEL_TARGET"`. That
  # matters because claude/cursor refuse to auto-approve any command containing
  # shell expansion, so a bare command is the only one that runs without a prompt.
  # A human invoking cartel directly (no CARTEL_TARGET) still defaults to $PWD.
  local id="" kind="" exec_override="" cwd="${CARTEL_TARGET:-$PWD}" worktree=0 brief="" brief_file="" extra=()
  local container="${CARTEL_DEFAULT_CONTAINER:-workspace}"
  [ $# -gt 0 ] || die "recruit: missing <id>"
  id="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="${2:-}"; shift 2 ;;
      --exec) exec_override="${2:-}"; shift 2 ;;
      --cwd) cwd="${2:-}"; shift 2 ;;
      --worktree) worktree=1; shift ;;
      --tab) container="tab"; shift ;;
      --workspace) container="workspace"; shift ;;
      --brief) brief="${2:-}"; shift 2 ;;
      --brief-file) brief_file="${2:-}"; shift 2 ;;
      --) shift; extra=("$@"); break ;;
      *) die "recruit: unknown option '$1' (put agent args after --)" ;;
    esac
  done
  case "$container" in workspace|tab) ;; *) die "invalid container '$container' (workspace|tab)" ;; esac

  valid_id "$id" || die "invalid id '$id' (must match [a-z][a-z0-9_-]{0,31})"
  [ -n "$kind" ] || die "recruit: --kind is required (cursor|claude)"
  # Refuse pi sicarios: pi has NO shell-guard hook wired (only claude+cursor bind
  # one), so a pi sicario would run FULLY unguarded - the destructive-op hard-block
  # the docs promise simply does not exist for it. Gate it here rather than ship a
  # false guarantee. (You can still run pi yourself, or seat it as the patrón.)
  [ "$kind" != pi ] || die "recruit: --kind pi is refused (no shell-guard hook exists for pi; a pi sicario would be unguarded). Use claude or cursor."
  local exec_cmd; exec_cmd=$(kind_exec "$kind") || die "unsupported --kind '$kind' (cursor|claude)"
  # --exec is a foot-gun: whatever it names becomes the pane process, and a
  # NON-agent process (e.g. /bin/bash) runs with NO PreToolUse/beforeShell guard
  # even though it is tagged CARTEL_SICARIO (nothing reads that tag but the hook,
  # which a raw shell never invokes). Restrict --exec to a bare command name (no
  # path, no spaces) on a small allowlist, so it can only ever be a real agent CLI
  # or a wrapper the operator explicitly trusts via CARTEL_EXEC_ALLOW.
  if [ -n "$exec_override" ]; then
    case "$exec_override" in
      ''|*/*|*[[:space:]]*) die "recruit: --exec must be a bare command name on the allowlist (no paths or spaces)" ;;
    esac
    case " cursor-agent claude pi ${CARTEL_EXEC_ALLOW:-} " in
      *" $exec_override "*) exec_cmd="$exec_override" ;;
      *) die "recruit: --exec '$exec_override' is not on the allowlist (opt in via CARTEL_EXEC_ALLOW='name ...'); refusing to launch an unguarded process as a sicario" ;;
    esac
  fi
  command -v "$exec_cmd" >/dev/null 2>&1 || die "executable '$exec_cmd' not found on PATH (for --kind $kind)"
  [ -d "$cwd" ] || die "cwd not a directory: $cwd"
  cwd=$(cd "$cwd" && pwd)
  [ ! -f "$(state_file "$id")" ] || die "sicario '$id' already exists (cartel bury $id first)"
  [ "$(agent_status "$id")" = exited ] || die "an agent named '$id' is already live in Herdr"
  if [ -n "$brief_file" ]; then [ -f "$brief_file" ] || die "brief-file not found: $brief_file"; brief=$(cat "$brief_file"); fi
  # A brief that starts with '-' is parsed by the agent CLI as a FLAG rather than a
  # prompt (e.g. --dangerously-skip-permissions -> a fully unrestricted sicario),
  # a privilege-escalation vector whenever the brief text is not fully trusted.
  # Refuse it (leading whitespace stripped first; covers --brief and --brief-file).
  case "${brief#"${brief%%[![:space:]]*}"}" in
    -*) die "recruit: --brief must not start with '-' (it would be read as an agent flag, not a task). Reword the brief." ;;
  esac

  # Serialize the herdr-mutation + state-write section so parallel recruits never
  # race on container/pane creation or root-pane cleanup. Released before the
  # (slow, best-effort) brief send so agents still run in parallel.
  lock_acquire 20 || die "busy: another cartel operation holds the lock ($CARTEL_LOCK)"
  trap 'lock_release' EXIT

  # 1. Session container.
  #    - workspace mode: a new left-sidebar space (herdr worktree/workspace).
  #    - tab mode: a new top tab in the CURRENT workspace; for --worktree we make
  #      the git worktree ourselves and open it as that tab.
  local out wsid tabid rootpane agentcwd checkout=""
  if [ "$container" = tab ]; then
    wsid=$(resolve_target_ws) || die "could not resolve a target workspace for --tab (run cartel inside your Herdr session)"
    if [ "$worktree" -eq 1 ]; then
      git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "--worktree needs a git repo, but $cwd is not one"
      checkout="$CARTEL_HOME/worktrees/$(basename "$cwd")/$id"
      mkdir -p "$(dirname "$checkout")"
      git -C "$cwd" worktree add -b "cartel/$id" "$checkout" >/dev/null 2>&1 \
        || die "git worktree add failed (branch cartel/$id may already exist)"
      agentcwd="$checkout"
    else
      agentcwd="$cwd"
    fi
    out=$(herdr tab create --workspace "$wsid" --cwd "$agentcwd" --label "cartel-$id" --no-focus) \
      || { [ "$worktree" -eq 1 ] && git -C "$cwd" worktree remove --force "$checkout" >/dev/null 2>&1; die "herdr tab create failed"; }
    tabid=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  elif [ "$worktree" -eq 1 ]; then
    git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || die "--worktree needs a git repo, but $cwd is not one"
    out=$(herdr worktree create --cwd "$cwd" --branch "cartel/$id" --label "cartel-$id" --no-focus --json) \
      || die "herdr worktree create failed"
    checkout=$(printf '%s' "$out" | jq -r '.result.worktree.path // empty')
    agentcwd="${checkout:-$cwd}"
    wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
    tabid=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  else
    out=$(herdr workspace create --cwd "$cwd" --label "cartel-$id" --no-focus) \
      || die "herdr workspace create failed"
    agentcwd="$cwd"
    wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
    tabid=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  fi
  rootpane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$wsid" ] && [ -n "$tabid" ] || die "could not read workspace/tab id from herdr response"

  # 2. Launch the agent CLI in that workspace (Herdr splits a fresh pane for it
  #    and returns the pane id). --cwd is required: agent start does not inherit
  #    the workspace cwd.
  #
  # Autonomy without the buggy --dangerously-skip-permissions flag: we tag the
  # sicario process with CARTEL_SICARIO so the shared shell-guard hook can
  # auto-approve ordinary commands and HARD-DENY the dangerous set (rm -rf, hard
  # reset, force-push, merge, rebase, ...) synchronously - a hook deny holds even
  # for a sicario, and unlike skip-permissions it can't race or reset mid-session.
  # File edits: worktree sicarios are isolated on their own branch, so we let them
  # apply edits without prompting (claude: acceptEdits mode; cursor: --force,
  # which still honours explicit denies + the hook). pi trusts project files (-a).
  # --trust (cursor) / -a (pi) skip the first-run workspace-trust gate so the
  # initial-prompt brief (appended below) isn't swallowed. claude has no such flag,
  # so a fresh worktree may still show a trust screen - handled by the note in (5).
  local -a autoflags=()
  case "$kind" in
    claude) [ "$worktree" -eq 1 ] && autoflags+=(--permission-mode acceptEdits) ;;
    cursor) autoflags+=(--trust); [ "$worktree" -eq 1 ] && autoflags+=(--force) ;;
    pi)     autoflags+=(-a) ;;
  esac
  local -a startcmd=(herdr agent start "$id" --workspace "$wsid" --tab "$tabid" \
    --cwd "$agentcwd" --env "CARTEL_SICARIO=$id" --no-focus -- "$exec_cmd")
  [ "${#autoflags[@]}" -gt 0 ] && startcmd+=("${autoflags[@]}")
  [ "${#extra[@]}" -gt 0 ] && startcmd+=("${extra[@]}")
  # Deliver the brief as the agent's INITIAL PROMPT (trailing positional): the
  # sicario boots already working on it, so we skip the readiness poll AND the
  # bracketed-paste Enter-settle dance that `agent send` needs - the single
  # biggest chunk of recruit latency, and the flakiest step.
  [ -n "$brief" ] && startcmd+=("$brief")
  local started apane
  started=$("${startcmd[@]}") \
    || { destroy_container "$container" "$worktree" "$wsid" "$tabid" "$cwd" "$checkout" "$id"; die "herdr agent start failed (is '$exec_cmd' installed and on PATH?)"; }
  apane=$(printf '%s' "$started" | jq -r '.result.agent.pane_id // empty')
  [ -n "$apane" ] || { destroy_container "$container" "$worktree" "$wsid" "$tabid" "$cwd" "$checkout" "$id"; die "agent start returned no pane id: $started"; }

  # 3. Remove the now-idle root shell pane so the tab holds only the agent.
  [ -z "$rootpane" ] || [ "$rootpane" = "$apane" ] || herdr pane close "$rootpane" >/dev/null 2>&1 || true

  # 4. Persist state before the (best-effort) brief send.
  jq -n --arg id "$id" --arg kind "$kind" --arg exec "$exec_cmd" --arg cwd "$cwd" \
        --arg acwd "$agentcwd" --arg container "$container" --arg wsid "$wsid" \
        --arg tabid "$tabid" --arg pane "$apane" --arg brief "$brief" \
        --arg co "$checkout" --argjson wt "$worktree" --arg created "$(date -u +%FT%TZ)" \
        '{id:$id,kind:$kind,exec:$exec,cwd:$cwd,agent_cwd:$acwd,container:$container,
          workspace_id:$wsid,tab_id:$tabid,pane_id:$pane,worktree:($wt==1),
          branch:(if $wt==1 then "cartel/\($id)" else null end),
          checkout:(if $co=="" then null else $co end),brief:$brief,created:$created}' \
        > "$(state_file "$id")"

  # Mutation done: drop the lock so other recruits proceed while we send the brief.
  lock_release; trap - EXIT

  # 5. The brief was delivered as the launch prompt, so the sicario is already
  #    working. Wait only until it has actually STARTED (so `await` won't mistake
  #    the still-booting idle state for a reply), open the reply record for
  #    correlation, and warn if a first-run trust/login screen is holding the task.
  local brief_note=""
  if [ -n "$brief" ]; then
    wait_started "$id" || true
    reply_open "$id" "$brief" 2>/dev/null || true
    if on_startup_gate "$id"; then
      brief_note=$'\n  ! sicario is on a first-run trust/login screen; the task is queued behind it.\n    Approve it (cartel focus '"$id"$' or cartel key '"$id"$' enter) and it will start;\n    if it does not, resend with: cartel order '"$id"$' "..."'
    fi
  fi

  printf 'recruited %s  kind=%s  status=%s  %s%s%s\n' \
    "$id" "$kind" "$(agent_status "$id")" \
    "$([ "$container" = tab ] && printf 'tab=%s (workspace %s)' "$tabid" "$wsid" || printf 'workspace=%s' "$wsid")" \
    "$([ "$worktree" -eq 1 ] && printf '  worktree=%s' "${checkout}")" "$brief_note"
}

# Emit one compact JSON object for a sicario, merging live status + reply state.
status_json_obj() {  # <state-file> <id>
  local f=$1 id=$2 st reply
  st=$(agent_status "$id")
  reply=$(jq -r '.state // "none"' "$(reply_file "$id")" 2>/dev/null || echo none)
  jq -c --arg st "$st" --arg reply "$reply" \
     '{id, kind, container, worktree, status:$st, reply:$reply,
       brief:(.brief // ""), pane_id, workspace_id, tab_id, created}' "$f"
}

cmd_ls() {
  local json=0; [ "${1:-}" = --json ] && json=1
  shopt -s nullglob
  local files=("$STATE_DIR"/*.json)
  if [ "$json" -eq 1 ]; then
    { local f id; for f in "${files[@]}"; do id=$(jq -r '.id' "$f" 2>/dev/null) || continue
        [ -n "$id" ] && status_json_obj "$f" "$id"; done; } | jq -s '.'
    return
  fi
  local f id kind wt st brief printed=0
  for f in "${files[@]}"; do
    id=$(jq -r '.id' "$f"); kind=$(jq -r '.kind' "$f")
    wt=$(jq -r 'if .worktree then "wt" else "ws" end' "$f")
    st=$(agent_status "$id")
    brief=$(jq -r '.brief // ""' "$f" | tr '\n' ' '); brief=${brief:0:52}
    printf '%-14s %-7s %-3s %-8s %s\n' "$id" "$kind" "$wt" "$st" "$brief"
    printed=1
  done
  [ "$printed" -eq 1 ] || printf 'no sicarios. cartel recruit <id> --kind <cursor|claude> ...\n'
}

cmd_status() {
  local json=0 args=() a
  for a in "$@"; do if [ "$a" = --json ]; then json=1; else args+=("$a"); fi; done
  set -- "${args[@]+"${args[@]}"}"
  if [ $# -eq 0 ]; then [ "$json" -eq 1 ] && cmd_ls --json || cmd_ls; return; fi
  local id="$1"; [ -f "$(state_file "$id")" ] || die "unknown sicario '$id'"
  if [ "$json" -eq 1 ]; then status_json_obj "$(state_file "$id")" "$id"; return; fi
  local st; st=$(agent_status "$id")
  printf '%s: %s\n' "$id" "$st"
  case "$st" in
    blocked) printf '  -> needs input. Inspect: cartel wire %s   Answer: cartel order %s "..."  or  cartel key %s <key>\n' "$id" "$id" "$id" ;;
    exited)  printf '  -> agent process is gone. Retire with: cartel bury %s\n' "$id" ;;
  esac
}

cmd_log() {
  [ $# -gt 0 ] || die "wire: missing <id>"
  local id="$1"; shift; local n=80
  case "${1:-}" in -n) n="${2:-80}";; esac
  [ -f "$(state_file "$id")" ] || die "unknown sicario '$id'"
  local tgt; tgt=$(agent_target "$id")
  local t; t=$(herdr agent read "$tgt" --source recent-unwrapped --lines "$n" 2>/dev/null | jq -r '.result.read.text // ""' 2>/dev/null || true)
  [ -n "$t" ] || t=$(herdr agent read "$tgt" --source visible --lines "$n" 2>/dev/null | jq -r '.result.read.text // ""' 2>/dev/null || true)
  printf '%s\n' "$t"
}

cmd_say() {
  [ $# -ge 2 ] || die "order: usage: cartel order <id> <text...>"
  local id="$1"; shift; local f; f=$(state_file "$id")
  [ -f "$f" ] || die "unknown sicario '$id'"
  submit_prompt "$id" "$(jq -r '.pane_id' "$f")" "$*" || die "send failed"
  reply_open "$id" "$*" 2>/dev/null || true
}

# Block until the sicario finishes the turn started by the last order/brief, then
# print its reply tail. Resolves the pending reply record. This is the sync half
# of reply correlation; `lookout` is the async half.
cmd_await() {
  [ $# -gt 0 ] || die "await: missing <id>"
  # Bounded by default so the patrón regains control (and can pick up a
  # newly-typed Don prompt) roughly every ~45s instead of being pinned for
  # minutes inside one blocking await. Raise with --timeout for a known-long job.
  local id="$1"; shift; local timeout=45 n=40
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="${2:-45}"; shift 2 ;;
      -n) n="${2:-40}"; shift 2 ;;
      *) die "await: unknown option '$1'" ;;
    esac
  done
  [ -f "$(state_file "$id")" ] || die "unknown sicario '$id'"

  # Event-driven path: cartel-events opens ONE subscription and does a race-free
  # subscribe-then-snapshot, so we react to the real transition with zero polling
  # of `herdr agent get`. Exit codes: 0 idle/done, 2 timeout, 3 blocked, 4 exited,
  # 5 setup failure (-> fall through to polling below).
  local ebin; ebin=$(events_bin)
  if [ -n "$ebin" ]; then
    local st rc
    # errexit-safe: cartel-events returns non-zero for blocked/exited/timeout/
    # setup-failure by design. A bare `st=$(...); rc=$?` would trip `set -e` and
    # kill the script before the case runs, so capture the code via `if`.
    if st=$("$ebin" --state "$STATE_DIR" --await "$id" --timeout "$timeout" \
            ${HERDR_SOCKET_PATH:+--socket "$HERDR_SOCKET_PATH"} 2>/dev/null); then
      rc=0
    else
      rc=$?
    fi
    case "$rc" in
      0) reply_resolve "$id" 2>/dev/null || true
         printf '%s replied (%s):\n' "$id" "$st"
         cmd_log "$id" -n "$n"
         return 0 ;;
      3) printf '%s is blocked (needs input). Inspect: cartel wire %s\n' "$id" "$id" >&2; return 3 ;;
      4) printf '%s exited before replying\n' "$id" >&2; return 4 ;;
      2) printf '%s still working after %ss (raise --timeout)\n' "$id" "$timeout" >&2; return 2 ;;
      *) : ;;  # 5 or unexpected -> fall through to polling
    esac
  fi

  # Polling fallback (no cartel-events, or it failed to set up).
  local deadline st; deadline=$(( $(date +%s) + timeout ))
  # Give a just-sent order a moment to move the agent off idle before we sample.
  sleep 1
  while :; do
    st=$(agent_status "$id")
    case "$st" in
      idle|done)
        reply_resolve "$id" 2>/dev/null || true
        printf '%s replied (%s):\n' "$id" "$st"
        cmd_log "$id" -n "$n"
        return 0 ;;
      blocked) printf '%s is blocked (needs input). Inspect: cartel wire %s\n' "$id" "$id" >&2; return 3 ;;
      exited)  printf '%s exited before replying\n' "$id" >&2; return 4 ;;
    esac
    [ "$(date +%s)" -ge "$deadline" ] && { printf '%s still working after %ss (raise --timeout)\n' "$id" "$timeout" >&2; return 2; }
    sleep 1
  done
}

cmd_key() {
  [ $# -ge 2 ] || die "key: usage: cartel key <id> <key...>"
  local id="$1"; shift; local f; f=$(state_file "$id")
  [ -f "$f" ] || die "unknown sicario '$id'"
  herdr pane send-keys "$(jq -r '.pane_id' "$f")" "$@"
}

cmd_wait() {
  [ $# -gt 0 ] || die "wait: missing <id>"
  local id="$1"; shift
  [ -f "$(state_file "$id")" ] || die "unknown sicario '$id'"
  local status=idle timeout=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status="${2:-idle}"; shift 2 ;;
      --timeout) timeout="${2:-}"; shift 2 ;;
      *) die "wait: unknown option '$1'" ;;
    esac
  done
  local tgt; tgt=$(agent_target "$id")
  if [ -n "$timeout" ]; then herdr agent wait "$tgt" --status "$status" --timeout "$timeout";
  else herdr agent wait "$tgt" --status "$status"; fi
}

cmd_focus() {
  [ $# -gt 0 ] || die "focus: missing <id>"
  [ -f "$(state_file "$1")" ] || die "unknown sicario '$1'"
  herdr agent focus "$(agent_target "$1")"
}

cmd_down() {
  [ $# -gt 0 ] || die "bury: missing <id>"
  local id="$1"; shift; local force=0
  case "${1:-}" in --force) force=1 ;; esac
  local f; f=$(state_file "$id"); [ -f "$f" ] || die "unknown sicario '$id'"
  local wsid tabid wt cwd checkout container branch
  wsid=$(jq -r '.workspace_id' "$f"); tabid=$(jq -r '.tab_id' "$f"); wt=$(jq -r '.worktree' "$f")
  cwd=$(jq -r '.cwd' "$f"); checkout=$(jq -r '.checkout // empty' "$f")
  container=$(jq -r '.container // "workspace"' "$f"); branch=$(jq -r '.branch // empty' "$f")

  # Fail-closed: never tear down unlanded work without --force. Uncommitted
  # changes OR commits that exist on no remote both count as unlanded.
  if [ "$wt" = true ] && [ "$force" -ne 1 ]; then
    if [ -n "$checkout" ] && [ -d "$checkout" ] && worktree_dirty "$checkout"; then
      die "sicario '$id' has uncommitted changes in its worktree. Commit them, or discard with: cartel bury $id --force"
    fi
    if [ -n "$branch" ] && branch_has_unpushed "$cwd" "$branch"; then
      die "sicario '$id' branch '$branch' has commits on no remote. Push them, or discard with: cartel bury $id --force"
    fi
  fi

  lock_acquire 20 || die "busy: another cartel operation holds the lock ($CARTEL_LOCK)"
  trap 'lock_release' EXIT
  if [ "$container" = tab ]; then
    # Quiesce the agent BEFORE touching the worktree: closing the tab stops the
    # sicario process so it can't write more files during teardown.
    herdr tab close "$tabid" >/dev/null 2>&1 || printf 'cartel: warning: tab close failed for %s\n' "$id" >&2
    if [ "$wt" = true ] && [ -n "$checkout" ] && [ -d "$checkout" ]; then
      if [ "$force" -eq 1 ]; then
        git -C "$cwd" worktree remove --force "$checkout" >/dev/null 2>&1 || true
      else
        # Non-force: agent is now stopped, so re-check for unlanded work to close
        # the TOCTOU window (the earlier guard ran while it was still live). Then
        # remove WITHOUT --force so git itself refuses a dirty worktree.
        if worktree_dirty "$checkout" || { [ -n "$branch" ] && branch_has_unpushed "$cwd" "$branch"; }; then
          die "sicario '$id' has unlanded work (detected after stopping it). Land it, or discard with: cartel bury $id --force  [worktree kept at: $checkout]"
        fi
        git -C "$cwd" worktree remove "$checkout" >/dev/null 2>&1 \
          || die "git refused to remove worktree for '$id' (uncommitted changes). Land it, or: cartel bury $id --force  [worktree kept at: $checkout]"
      fi
      [ -d "$checkout" ] || rmdir "$(dirname "$checkout")" 2>/dev/null || true
    fi
  elif [ "$wt" = true ]; then
    # Prefer Herdr's worktree remove (drops the checkout + workspace together).
    # If Herdr no longer knows the workspace (e.g. you closed the tab), fall
    # back to a plain git worktree remove so the checkout never leaks. Only
    # force-discard when --force was explicitly given; otherwise re-check and let
    # git refuse a dirty worktree (TOCTOU-safe teardown).
    if [ "$force" -eq 1 ]; then
      herdr worktree remove --workspace "$wsid" --force >/dev/null 2>&1 || true
      [ -z "$checkout" ] || [ ! -d "$checkout" ] || git -C "$cwd" worktree remove --force "$checkout" >/dev/null 2>&1 || true
    else
      if [ -n "$checkout" ] && [ -d "$checkout" ] && { worktree_dirty "$checkout" || { [ -n "$branch" ] && branch_has_unpushed "$cwd" "$branch"; }; }; then
        die "sicario '$id' has unlanded work. Land it, or discard with: cartel bury $id --force  [worktree kept at: $checkout]"
      fi
      herdr worktree remove --workspace "$wsid" >/dev/null 2>&1 || true
      [ -z "$checkout" ] || [ ! -d "$checkout" ] || git -C "$cwd" worktree remove "$checkout" >/dev/null 2>&1 || true
    fi
  else
    herdr workspace close "$wsid" >/dev/null 2>&1 || printf 'cartel: warning: workspace close failed for %s\n' "$id" >&2
  fi
  rm -f "$f"; reply_clear "$id"
  lock_release; trap - EXIT

  if [ "$wt" = true ] && [ -n "$branch" ]; then
    if [ "$force" -eq 1 ]; then
      git -C "$cwd" branch -D "$branch" >/dev/null 2>&1 || true
      printf 'buried %s (branch %s discarded)\n' "$id" "$branch"
    else
      printf 'buried %s (branch %s kept: git -C %s branch -D %s to remove)\n' "$id" "$branch" "$cwd" "$branch"
    fi
  else
    printf 'buried %s\n' "$id"
  fi
}

cmd_patron() {
  local kind=claude target="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="${2:-claude}"; shift 2 ;;
      --cwd|--target) target="${2:-}"; shift 2 ;;
      *) die "patron: unknown option '$1'" ;;
    esac
  done
  local caphome="$CARTEL_HOME/patron"
  local cap="$caphome/AGENTS.md"
  [ -f "$cap" ] || die "patron instructions not found: $cap"
  [ -d "$target" ] || die "target repo not a directory: $target"
  target=$(cd "$target" && pwd)
  local instr; instr=$(cat "$cap")
  # The patrón works ON $target but RUNS FROM its own home so AGENTS.md /
  # CLAUDE.md load as strong PROJECT memory. A bare --append-system-prompt is
  # too weak to override the global ~/.claude/CLAUDE.md "just execute" defaults,
  # which is why an in-repo patrón ends up doing the work itself. Sicarios still
  # target the repo via CARTEL_TARGET, and --tab recruits land beside you
  # because HERDR_WORKSPACE_ID is inherited from the launching tab.
  #
  # Materialize the instructions as REAL files in a writable run dir. When
  # installed via home-manager, $caphome/{AGENTS,CLAUDE}.md are symlinks into
  # /nix/store, and claude refuses to import an AGENTS.md that resolves outside
  # the workspace ("reading AGENTS.md was denied") - silently dropping the
  # delegate-only rules. Copying to real files restores strong project memory and
  # keeps the dir writable for the agent's own session files (.claude/, etc.).
  local rundir="$CARTEL_HOME/.patron-run"
  mkdir -p "$rundir"
  cat "$cap" > "$rundir/AGENTS.md"
  printf '@AGENTS.md\n' > "$rundir/CLAUDE.md"
  export CARTEL_TARGET="$target"
  cd "$rundir"
  printf 'seating the patrón (%s); target repo: %s\n' "$kind" "$target" >&2

  # Background notifier: the instant any sicario finishes / blocks / exits, push
  # a report-trigger straight into THIS pane so the patrón reports it without you
  # asking and without ever blocking on `await`. It self-terminates when this
  # pane closes. Output goes to a log (never this terminal - it would corrupt the
  # agent TUI). Requires running inside Herdr (HERDR_PANE_ID set).
  #
  # SINGLETON PER PANE: re-seating a patrón in the same pane (or seating one after
  # a rebuild) must NOT leave the previous lookout running - two lookouts on one
  # pane each deliver the same events, so you get every report twice (and, across
  # a rebuild, in two different wordings). Kill the recorded prior lookout for
  # this pane, then record the new one.
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    local lookpid_file="$STATE_DIR/lookout.${HERDR_PANE_ID}.pid" oldpid
    if [ -f "$lookpid_file" ]; then
      oldpid=$(cat "$lookpid_file" 2>/dev/null || true)
      case "$oldpid" in
        ''|*[!0-9]*) : ;;
        *) if kill -0 "$oldpid" 2>/dev/null; then
             case "$(ps -o comm= -p "$oldpid" 2>/dev/null)" in
               *bash*|*cartel*|*sh) kill "$oldpid" 2>/dev/null || true ;;
             esac
           fi ;;
      esac
    fi
    ( cmd_watch --notify-pane "$HERDR_PANE_ID" --on done,idle,blocked,exited --no-bell ) \
      >>"$STATE_DIR/patron-lookout.log" 2>&1 &
    printf '%s\n' "$!" > "$lookpid_file" 2>/dev/null || true
    disown 2>/dev/null || true
  fi

  case "$kind" in
    claude)
      # Auto-approve ONLY the `cartel` command (scoped, not a blanket skip); the
      # instructions ride the invisible system prompt + CLAUDE.md, so nothing is
      # pasted into the chat.
      exec claude \
        --add-dir "$target" \
        --allowedTools "Bash(cartel:*),Bash(cartel *)" \
        --append-system-prompt "$instr" ;;
    pi)
      # -a trusts the project-local AGENTS.md so pi loads it without a prompt; the
      # instructions ride the invisible system prompt, so nothing is pasted.
      exec pi -a --append-system-prompt "$instr" ;;
    cursor)
      # cursor-agent has no system-prompt flag, so rather than paste the whole
      # brief into the chat we load it as an always-on PROJECT RULE (silent),
      # scoped to this run dir only.
      #
      # We deliberately do NOT touch the global ~/.cursor/cli-config.json: adding
      # Shell(cartel) there would let EVERY future Cursor session (in any repo)
      # spawn autonomous sicarios without approval. That is a standing privilege
      # escalation with no rollback, so we leave `cartel` approval-gated in Cursor
      # and just tell the user how to opt in per their own judgement.
      mkdir -p "$rundir/.cursor/rules"
      {
        printf -- '---\ndescription: patrón orchestrator\nalwaysApply: true\n---\n\n'
        printf 'Your target repo is %s (also in $CARTEL_TARGET).\n\n' "$target"
        cat "$rundir/AGENTS.md"
      } > "$rundir/.cursor/rules/patron.mdc"
      printf 'note: Cursor will ask before each `cartel` command. To skip that permanently\n' >&2
      printf '      (broadens ALL Cursor sessions), add "Shell(cartel)" under permissions.allow\n' >&2
      printf '      in ~/.cursor/cli-config.json yourself.\n' >&2
      exec cursor-agent --trust ;;
    *) die "patron: unsupported --kind '$kind' (cursor|claude|pi)" ;;
  esac
}

cmd_watch() {
  local interval=5 states="blocked done exited" notify_agent="" notify_pane="" bell=1 poll=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) interval="${2:-5}"; shift 2 ;;
      --on) states=$(printf '%s' "${2:-}" | tr ',' ' '); shift 2 ;;
      --notify-agent) notify_agent="${2:-}"; shift 2 ;;
      --notify-pane) notify_pane="${2:-}"; shift 2 ;;
      --no-bell) bell=0; shift ;;
      --poll) poll=1; shift ;;
      *) die "lookout: unknown option '$1'" ;;
    esac
  done
  case "$interval" in ''|*[!0-9]*) die "lookout: --interval must be an integer" ;; esac

  # Shared across event mode AND the polling fallback: if the event stream drops
  # mid-session, polling must NOT re-baseline from scratch (that silently swallows
  # any sicario already settled at the switchover - "nothing reported"). Keeping
  # one history means a settle that happens around the gap still fires a report.
  declare -A prev reported

  in_set() { case " $states " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  notify() {  # <id> <state>
    local id=$1 st=$2 body sound line
    case "$st" in
      blocked) body="needs input"; sound=request ;;
      done)    body="finished";    sound=done ;;
      idle)    body="finished";    sound=done ;;
      exited)  body="process exited"; sound=request ;;
      replied) body="responded to your order"; sound=done ;;
      *)       body="$st";         sound=none ;;
    esac
    line="$(date +%H:%M:%S)  $id -> $st ($body)"
    printf '%s%s\n' "$line" "$([ "$bell" -eq 1 ] && printf '\a')"
    printf '%s\n' "$line" >> "$STATE_DIR/watch.log"
    herdr notification show "cartel: $id $st" --body "$body" --sound "$sound" >/dev/null 2>&1 || true
    [ -z "$notify_agent" ] || nudge_agent "$notify_agent" \
      "[cartel] sicario '$id' -> $st ($body). Run: cartel wire $id  then handle or report it."
    # Queue a report into the patrón's pane. Delivery is done by the drain ticker
    # ONLY (not here): it gates on an empty composer so a report never lands over
    # your prompt line, and it coalesces everything queued since the last tick
    # into ONE nudge, so several sicarios finishing together don't each spam a
    # line. If the pane is gone (patrón exited), stop the notifier so we never
    # leak it.
    if [ -n "$notify_pane" ]; then
      if herdr pane get "$notify_pane" >/dev/null 2>&1; then
        report_enqueue "$id" "$st"
      else
        exit 0
      fi
    fi
  }
  # One transition -> reply correlation + policy alert. Uses caller's `prev` and
  # `reported` maps (bash dynamic scope).
  handle_transition() {  # <id> <status>
    local id=$1 st=$2 old=${prev[$id]-NEW}
    [ "$st" = "$old" ] && return
    prev[$id]=$st
    # A move (back) to working begins a NEW turn: re-arm reporting so its eventual
    # settle is reported again.
    case "$st" in working) reported[$id]="" ;; esac
    # In pane-notify mode we fire a single message per settle, so skip the
    # separate reply-correlation alert to avoid double-pinging the patrón.
    if [ -z "$notify_pane" ]; then
      case "$st" in idle|done) reply_resolve "$id" 2>/dev/null && notify "$id" replied ;; esac
    fi
    in_set "$st" || return
    # Collapse ONE sicario's whole finish into a single report: herdr emits done
    # THEN idle (and can flap done<->idle), which would otherwise nudge 2-3x per
    # finish. Report a settled/blocked/exited state only once per busy->settle
    # cycle; the working reset above re-arms it for a genuinely new result.
    [ -n "${reported[$id]-}" ] && return
    reported[$id]=1
    notify "$id" "$st"
  }

  # Event mode: stream transitions from the Go source (instant, no polling).
  # It prints "@ready" then TAB-separated "<id>\t<status>" per transition.
  run_event_mode() {  # <events-bin>
    local bin=$1 f id st
    shopt -s nullglob
    # Baseline current states. Pre-mark any sicario already settled at startup as
    # reported, so a later idle<->done flap doesn't nudge a result that predates
    # this watcher.
    for f in "$STATE_DIR"/*.json; do id=$(jq -r '.id' "$f" 2>/dev/null) || continue
      [ -n "$id" ] || continue
      st=$(agent_status "$id"); prev[$id]=$st
      in_set "$st" && reported[$id]=1 || true
    done
    while IFS=$'\t' read -r id st; do
      if [ "$id" = "@ready" ]; then printf 'cartel lookout: event stream live (instant).\n'; continue; fi
      [ -n "${id:-}" ] && [ -n "${st:-}" ] || continue
      handle_transition "$id" "$st"
    done < <("$bin" --state "$STATE_DIR" ${HERDR_SOCKET_PATH:+--socket "$HERDR_SOCKET_PATH"} 2>>"$STATE_DIR/events.log")
    return 1   # stream ended -> signal fallback
  }

  # Drain ticker: the SOLE deliverer of pane reports. Every interval it flushes
  # whatever transitions were queued since the last tick as ONE coalesced nudge,
  # but only when your composer is empty - so reports never land over your prompt
  # line and near-simultaneous finishes collapse into a single message instead of
  # one line each.
  #
  # It is also the ONLY reliable place that notices the patrón pane has closed:
  # the main loop below blocks on the event stream (which outlives the pane), so a
  # bare `exit 0` here would kill only this subshell and leave the parent lookout
  # orphaned under PID 1. Kill the parent explicitly ($self_pid) so its TERM trap
  # tears everything down (this ticker + the event stream) and nothing lingers.
  local drain_pid="" self_pid=$BASHPID
  if [ -n "$notify_pane" ]; then
    # `herdr pane get` shares the same flaky socket as everything else, so a SINGLE
    # failure must NOT tear down the notifier (that was killing the ticker on a
    # transient hiccup and silently ending all reporting). Require several
    # CONSECUTIVE failures before concluding the pane is really gone. Also guard
    # report_try_deliver with `|| true` so a stray non-zero can't kill the ticker
    # under `set -e`.
    ( miss=0
      while sleep "$interval"; do
        if herdr pane get "$notify_pane" >/dev/null 2>&1; then
          miss=0
        else
          miss=$((miss + 1))
          [ "$miss" -ge 3 ] && { kill "$self_pid" 2>/dev/null; exit 0; }
          continue
        fi
        report_try_deliver "$notify_pane" || true
      done ) &
    drain_pid=$!
  fi

  trap '[ -n "$drain_pid" ] && kill "$drain_pid" 2>/dev/null; printf "\ncartel lookout stopped\n"; exit 0' INT TERM
  printf 'cartel lookout: alert on [%s]%s%s. Ctrl-C to stop.\n' \
    "$states" \
    "$([ -n "$notify_agent" ] && printf ', nudge=%s' "$notify_agent")" \
    "$([ "$bell" -eq 1 ] && printf ', bell on')"

  # Only silently baseline when we have NO history yet. Once `prev` is populated
  # (from event mode or a prior poll burst) we report transitions immediately,
  # instead of swallowing settles that occurred around a switchover.
  # NOTE: under `set -u`, `${#prev[@]}` on an EMPTY associative array throws
  # "unbound variable" in bash 5.x (a long-standing assoc-array quirk) - which
  # would crash the whole lookout at startup. `${prev[*]+x}` is nounset-safe:
  # it yields "x" only when the array has at least one element.
  local baselined=0
  [ -n "${prev[*]+x}" ] && baselined=1
  shopt -s nullglob

  # One polling scan pass. Reports transitions via handle_transition; exits the
  # whole lookout if the patrón pane is gone. Shares prev/reported/baselined with
  # the enclosing scope (no subshell), so state carries across event<->poll.
  poll_once() {
    local f id st
    if [ -n "$notify_pane" ] && ! herdr pane get "$notify_pane" >/dev/null 2>&1; then
      exit 0
    fi
    for f in "$STATE_DIR"/*.json; do
      id=$(jq -r '.id' "$f" 2>/dev/null) || continue
      [ -n "$id" ] || continue
      st=$(agent_status "$id")
      if [ "$baselined" -eq 0 ]; then prev[$id]=$st; in_set "$st" && reported[$id]=1 || true; continue; fi
      handle_transition "$id" "$st"
    done
    baselined=1
    # Backstop delivery: don't rely solely on the drain ticker (if it ever dies,
    # enqueued reports would rot). Every poll pass also flushes the queue.
    [ -n "$notify_pane" ] && { report_try_deliver "$notify_pane" || true; }
  }

  local ebin; ebin=$(events_bin)

  # No Go binary (or --poll): plain polling forever.
  if [ "$poll" -eq 1 ] || [ -z "$ebin" ]; then
    printf 'cartel lookout: polling every %ss.\n' "$interval"
    while true; do poll_once; sleep "$interval"; done
  fi

  # Self-healing supervisor: prefer instant event mode; when the stream drops
  # (transient herdr hiccup, or the Go client giving up), cover the gap with a
  # short polling burst so nothing is missed, then RE-ENTER event mode. A drop is
  # therefore never a permanent downgrade to polling - we return to sub-second
  # reporting as soon as herdr is healthy again. run_event_mode BLOCKS while the
  # stream is live, so the poll burst only runs during an actual outage.
  local gap_cycles=6   # ~= gap_cycles*interval seconds of polling coverage per drop
  while true; do
    run_event_mode "$ebin" || true
    printf 'cartel lookout: event stream dropped; polling ~%ss then retrying instant mode.\n' \
      "$((gap_cycles * interval))" >&2
    local i=0
    while [ "$i" -lt "$gap_cycles" ]; do poll_once; sleep "$interval"; i=$((i + 1)); done
  done
}

main() {
  # Bare `cartel` (or `cartel --kind ... / --cwd ...`) seats the patrón in the
  # current repo - the one agent you talk to. Everything else is an explicit verb.
  local sub
  if [ $# -eq 0 ]; then
    sub=patron
  elif [ "${1#-}" != "$1" ]; then      # first arg is an option, not a verb
    case "$1" in -h|--help) sub=help; shift ;; *) sub=patron ;; esac
  else
    sub="$1"; shift
  fi
  case "$sub" in
    recruit|up) cmd_up "$@" ;;
    patron|captain) cmd_patron "$@" ;;
    lookout|watch) cmd_watch "$@" ;;
    roster|ls|list) cmd_ls "$@" ;;
    status|st) cmd_status "$@" ;;
    wire|log) cmd_log "$@" ;;
    order|say) cmd_say "$@" ;;
    await) cmd_await "$@" ;;
    key|signal) cmd_key "$@" ;;
    wait) cmd_wait "$@" ;;
    focus) cmd_focus "$@" ;;
    bury|silence|down|rm) cmd_down "$@" ;;
    help|-h|--help) usage ;;
    *) usage; die "unknown command '$sub'" ;;
  esac
}

main "$@"
