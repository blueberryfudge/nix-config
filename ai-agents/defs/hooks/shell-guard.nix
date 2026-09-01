{
  pkgs,
  # Pattern lists are injected from the ai-agents module so the shell-guard hook
  # and Claude's permission deny/ask lists stay in sync from a single source.
  destructiveRegexes,
  # Extra hard-denies that apply ONLY to cartel sicarios (processes tagged with
  # $CARTEL_SICARIO). Interactive/human sessions are unaffected by these.
  sicarioDenyRegexes ? [ ],
  networkTokens,
}:
let
  destructiveTest = builtins.concatStringsSep " || " (
    map (r: ''[[ "$command" =~ ${r} ]]'') destructiveRegexes
  );
  sicarioDenyTest =
    if sicarioDenyRegexes == [ ] then
      "false"
    else
      builtins.concatStringsSep " || " (map (r: ''[[ "$command" =~ ${r} ]]'') sicarioDenyRegexes);
  networkRegex = "(^|[[:space:]])(" + builtins.concatStringsSep "|" networkTokens + ")([[:space:]]|$)";
in
{
  description = "Block destructive shell commands, ask before networked ones, and auto-approve safe commands for cartel sicarios.";
  fileName = "shell-guard.sh";
  script = ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    input="$(${pkgs.coreutils}/bin/cat)"
    jq_bin="${pkgs.jq}/bin/jq"

    command="$("$jq_bin" -r '.tool_input.command // .command // empty' <<<"$input")"

    # Claude sends {tool_input:{command}}; Cursor sends {command} and expects a
    # JSON permission verdict on stdout. Detect which so we answer in the right form.
    is_claude="false"
    if "$jq_bin" -e 'has("tool_input")' >/dev/null <<<"$input"; then
      is_claude="true"
    fi

    # Present iff this process is a cartel sicario (see `cartel recruit`, which
    # starts the agent with --env CARTEL_SICARIO=<id>). Used to grant autonomy
    # (auto-approve ordinary commands) while still HARD-DENYING the dangerous set.
    sicario="''${CARTEL_SICARIO:-}"

    emit_allow() {
      if [ "$is_claude" = "true" ]; then
        "$jq_bin" -n '{ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: "cartel sicario: auto-approved (dangerous ops are hard-denied)" } }'
      else
        "$jq_bin" -n '{ continue: true, permission: "allow" }'
      fi
      exit 0
    }

    deny() {
      local reason="$1"
      if [ "$is_claude" = "true" ]; then
        echo "$reason" >&2
        exit 2
      else
        "$jq_bin" -n --arg r "$reason" \
          '{ continue: true, permission: "deny", user_message: $r, agent_message: $r }'
        exit 0
      fi
    }

    if [ -z "$command" ]; then
      # Nothing to inspect (e.g. a non-shell tool call). Stay out of the way.
      if [ "$is_claude" = "true" ]; then
        exit 0
      else
        "$jq_bin" -n '{ continue: true, permission: "allow" }'
        exit 0
      fi
    fi

    # 1. Destructive commands are blocked for EVERYONE, sicario or not.
    if ${destructiveTest}; then
      deny "Blocked destructive shell command: $command"
    fi

    # 2. Sicario-only hard-denies: irreversible / history-rewriting git ops. These
    #    hold even though the sicario is otherwise autonomous.
    if [ -n "$sicario" ]; then
      if ${sicarioDenyTest}; then
        deny "Blocked for cartel sicario (irreversible git op - do this yourself or via the patrón): $command"
      fi
    fi

    # 3. Network-capable commands: ask before running (a sicario escalates to the
    #    patrón/Don rather than reaching the network unattended).
    if [[ "$command" =~ ${networkRegex} ]]; then
      if [ "$is_claude" = "true" ]; then
        exit 0
      else
        "$jq_bin" -n --arg command "$command" \
          '{
            continue: true,
            permission: "ask",
            user_message: ("Network-capable shell command requires approval: " + $command),
            agent_message: ("The command \"" + $command + "\" can reach external systems. Ask the user before continuing.")
          }'
        exit 0
      fi
    fi

    # 4. Everything else. Sicarios run it without a prompt (that is the whole point
    #    of the autonomous crew); human sessions fall through to their normal rules.
    if [ -n "$sicario" ]; then
      emit_allow
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
