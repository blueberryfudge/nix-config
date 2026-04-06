{ pkgs }:
{
  description = "Inject lightweight repo and host context at session start.";
  fileName = "session-context.sh";
  script = ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    input="$(${pkgs.coreutils}/bin/cat)"
    jq_bin="${pkgs.jq}/bin/jq"
    cwd="$("$jq_bin" -r '.cwd // empty' <<<"$input")"
    if [ -z "$cwd" ]; then
      cwd="$PWD"
    fi

    host="$(${pkgs.hostname}/bin/hostname -s 2>/dev/null || ${pkgs.hostname}/bin/hostname)"
    repo_root="$(${pkgs.git}/bin/git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"
    branch="$(${pkgs.git}/bin/git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'detached-or-none')"

    cat <<EOF
    Session context:
    - host: $host
    - working directory: $cwd
    - repo root: $repo_root
    - git branch: $branch
    EOF
  '';
  claude = [
    {
      event = "SessionStart";
      matcher = "startup|resume";
      timeout = 10;
    }
  ];
}
