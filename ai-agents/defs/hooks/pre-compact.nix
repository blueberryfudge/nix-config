{ pkgs }:
{
  description = "Append a timestamped checkpoint to ~/.claude/compact-notes.md before context compaction.";
  fileName = "pre-compact.sh";
  script = ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    input="$(${pkgs.coreutils}/bin/cat)"
    jq_bin="${pkgs.jq}/bin/jq"
    timestamp="$(${pkgs.coreutils}/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"

    cwd="$("$jq_bin" -r '.cwd // empty' <<<"$input" 2>/dev/null || printf '%s' "$PWD")"
    if [ -z "$cwd" ]; then cwd="$PWD"; fi

    branch="$(${pkgs.git}/bin/git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')"

    notes_file="$HOME/.claude/compact-notes.md"
    {
      printf '## %s\n' "$timestamp"
      printf '%s\n' "- branch: $branch"
      printf '%s\n' "- cwd: $cwd"
      printf '\n### Recent commits\n'
      ${pkgs.git}/bin/git -C "$cwd" log --oneline -5 2>/dev/null || true
      printf '\n### Modified files\n'
      ${pkgs.git}/bin/git -C "$cwd" diff --name-only 2>/dev/null || true
      printf '\n### Working tree\n'
      ${pkgs.git}/bin/git -C "$cwd" status --short 2>/dev/null || true
      printf '\n'
    } >> "$notes_file"
  '';
  claude = [
    {
      event = "PreCompact";
      timeout = 10;
    }
  ];
}
