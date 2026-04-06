{ pkgs }:
{
  description = "Block destructive shell commands and ask before networked shell commands.";
  fileName = "shell-guard.sh";
  script = ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    input="$(${pkgs.coreutils}/bin/cat)"
    jq_bin="${pkgs.jq}/bin/jq"

    command="$("$jq_bin" -r '.tool_input.command // .command // empty' <<<"$input")"
    if [ -z "$command" ]; then
      if "$jq_bin" -e 'has("tool_input")' >/dev/null <<<"$input"; then
        exit 0
      else
        "$jq_bin" -n '{ continue: true, permission: "allow" }'
        exit 0
      fi
    fi

    is_claude="false"
    if "$jq_bin" -e 'has("tool_input")' >/dev/null <<<"$input"; then
      is_claude="true"
    fi

    if [[ "$command" =~ rm[[:space:]]+-rf([[:space:]]|$) ]] || [[ "$command" =~ git[[:space:]]+reset[[:space:]]+--hard([[:space:]]|$) ]] || [[ "$command" =~ git[[:space:]]+clean[[:space:]]+-fd[a-zA-Z-]*([[:space:]]|$) ]]; then
      if [ "$is_claude" = "true" ]; then
        echo "Blocked destructive shell command: $command" >&2
        exit 2
      else
        "$jq_bin" -n \
          --arg command "$command" \
          '{
            continue: true,
            permission: "deny",
            user_message: ("Destructive shell command blocked: " + $command),
            agent_message: ("The command \"" + $command + "\" matches a destructive pattern and was denied.")
          }'
        exit 0
      fi
    fi

    if [[ "$command" =~ (^|[[:space:]])(curl|wget|nc|ncat|ssh|scp|rsync)([[:space:]]|$) ]]; then
      if [ "$is_claude" = "true" ]; then
        exit 0
      else
        "$jq_bin" -n \
          --arg command "$command" \
          '{
            continue: true,
            permission: "ask",
            user_message: ("Network-capable shell command requires approval: " + $command),
            agent_message: ("The command \"" + $command + "\" can reach external systems. Ask the user before continuing.")
          }'
        exit 0
      fi
    fi

    if [ "$is_claude" = "true" ]; then
      exit 0
    else
      "$jq_bin" -n '{ continue: true, permission: "allow" }'
    fi
  '';
  claude = [
    {
      event = "PreToolUse";
      matcher = "Bash";
      timeout = 10;
    }
  ];
  cursor = [
    {
      event = "beforeShellExecution";
      timeout = 10;
      failClosed = true;
    }
  ];
}
