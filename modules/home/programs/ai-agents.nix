{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.ai-agents;
  dataDir = ../../../ai-agents;
  dataPath = subpath: dataDir + "/${subpath}";
  targetTierModels = {
    claude = {
      fast = "claude-haiku-4-5-20251001";
      balanced = "claude-sonnet-4-6";
      reasoning = "claude-opus-4-6";
    };
    cursor = {
      fast = "fast";
      balanced = "claude-sonnet-4-6";
      reasoning = "claude-opus-4-6";
    };
  };
  agentDefs = {
    code-architect = import (dataPath "defs/agents/code-architect.nix");
    code-engineer = import (dataPath "defs/agents/code-engineer.nix");
    code-reviewer = import (dataPath "defs/agents/code-reviewer.nix");
    code-security = import (dataPath "defs/agents/code-security.nix");
    code-searcher = import (dataPath "defs/agents/code-searcher.nix");
  };

  skillDefs = {
    commit = import (dataPath "defs/skills/commit.nix");
    nix-module-workflow = import (dataPath "defs/skills/nix-module-workflow.nix");
    session-resume = import (dataPath "defs/skills/session-resume.nix");
    skill-creator = import (dataPath "defs/skills/skill-creator.nix");
    specialist-routing = import (dataPath "defs/skills/specialist-routing.nix");
  };

  # Single source of truth for guarded shell commands. Both Claude's permission
  # lists (below) and the shell-guard hook (which also covers Cursor, Codex and
  # Pi, none of which have Claude's permission system) derive from these.
  guardedNetwork = [
    "curl"
    "wget"
    "nc"
    "ncat"
    "ssh"
    "scp"
    "rsync"
  ];

  guardedDestructive = [
    { perm = "Bash(rm -rf *)"; regex = "rm[[:space:]]+-rf([[:space:]]|$)"; }
    { perm = "Bash(git reset --hard *)"; regex = "git[[:space:]]+reset[[:space:]]+--hard([[:space:]]|$)"; }
    { perm = "Bash(git clean -fd *)"; regex = "git[[:space:]]+clean[[:space:]]+-fd[a-zA-Z-]*([[:space:]]|$)"; }
  ];

  # Extra hard-denies that apply ONLY to cartel sicarios (autonomous worker
  # agents tagged with $CARTEL_SICARIO), on top of guardedDestructive. Your own
  # interactive sessions are unaffected - you can still merge/rebase/force-push.
  # Plain `git push` is deliberately NOT here, so worktree sicarios can land their
  # branches/PRs; only history-rewriting / irreversible git ops are blocked.
  guardedSicarioExtra = [
    { regex = "git[[:space:]]+push([[:space:]].*)?[[:space:]](-f|--force|--force-with-lease)([[:space:]]|=|$)"; }
    { regex = "git[[:space:]]+merge([[:space:]]|$)"; }
    { regex = "git[[:space:]]+rebase([[:space:]]|$)"; }
    { regex = "git[[:space:]]+branch[[:space:]]+(-[dD]|--delete)[[:space:]]+(main|master)([[:space:]]|$)"; }
  ];

  hookDefs = {
    shell-guard = import (dataPath "defs/hooks/shell-guard.nix") {
      inherit pkgs;
      destructiveRegexes = map (d: d.regex) guardedDestructive;
      sicarioDenyRegexes = map (d: d.regex) guardedSicarioExtra;
      networkTokens = guardedNetwork;
    };
    session-context = import (dataPath "defs/hooks/session-context.nix") { inherit pkgs; };
    pre-compact = import (dataPath "defs/hooks/pre-compact.nix") { inherit pkgs; };
  };

  ruleDefs = {
    shared-defaults = import (dataPath "defs/rules/shared-defaults.nix");
  };

  claudePermissions = {
    allow = [
      "Bash(git status)"
      "Bash(git diff *)"
      "Bash(but status *)"
      "Bash(but show *)"
      "Bash(but diff *)"
      "Bash(but log *)"
      "Bash(but branch *)"
      "Bash(but commit *)"
      "Bash(but pr *)"
      "Bash(but absorb *)"
      "Bash(but amend *)"
      "Bash(but squash *)"
      "Bash(but move *)"
      "Bash(but reword *)"
      "Bash(but undo *)"
      "Bash(but uncommit *)"
      "Bash(but skill *)"
      "Bash(nix eval *)"
      "Bash(nix build *)"
      "Bash(nix flake check *)"
    ];
    ask = (map (t: "Bash(${t} *)") guardedNetwork) ++ [
      "Bash(git push *)"
      "Bash(but push *)"
      "Bash(nix flake update *)"
      "Bash(home-manager switch *)"
      "Bash(darwin-rebuild switch *)"
    ];
    deny = (map (d: d.perm) guardedDestructive) ++ [
      "Read(./secrets/**)"
      "Read(./**/*.age)"
      "Read(./**/.env*)"
      "Skill(skill-creator)"
    ];
  };

  renderYamlLine =
    key: value:
    if value == null then
      ""
    else
      "${key}: ${builtins.toJSON value}";

  orderedAttrNames = attrs: builtins.sort builtins.lessThan (builtins.attrNames attrs);

  renderFrontmatter =
    attrs:
    let
      lines = builtins.filter (line: line != "") (
        map (name: renderYamlLine name attrs.${name}) (orderedAttrNames attrs)
      );
    in
    ''
      ---
      ${lib.concatStringsSep "\n" lines}
      ---

    '';

  resolveModel =
    target: name: agent:
    if agent ? models && builtins.hasAttr target agent.models then
      agent.models.${target}
    else if agent ? model then
      agent.model
    else if agent ? tier && builtins.hasAttr agent.tier targetTierModels.${target} then
      targetTierModels.${target}.${agent.tier}
    else if agent ? tier then
      throw "Unknown ai-agents tier `${agent.tier}` for `${name}` on target `${target}`"
    else
      null;

  renderAgent =
    target: name: agent:
    let
      model = resolveModel target name agent;
      frontmatter =
        {
          inherit name;
          description = agent.description;
        }
        // (agent.frontmatter or { })
        // lib.optionalAttrs (model != null) { inherit model; }
        // (agent.${target} or { });
    in
    ''
      ${renderFrontmatter frontmatter}
      ${agent.prompt}
    '';

  renderSkill =
    target: name: skill:
    let
      frontmatter =
        {
          inherit name;
          description = skill.description;
        }
        // (skill.frontmatter or { })
        // (skill.${target} or { });
    in
    ''
      ${renderFrontmatter frontmatter}
      ${skill.content}
    '';

  renderCursorRule =
    name: rule:
    let
      frontmatter = {
        description = rule.description;
      } // (rule.frontmatter or { });
    in
    ''
      ${renderFrontmatter frontmatter}
      ${rule.content}
    '';

  mkAgentEntries =
    target: base:
    lib.mapAttrs' (
      name: agent:
      lib.nameValuePair "${base}/agents/${name}.md" {
        text = renderAgent target name agent;
      }
    ) agentDefs;

  mkSkillEntries =
    target: base:
    lib.mapAttrs' (
      name: skill:
      lib.nameValuePair "${base}/skills/${name}/SKILL.md" {
        text = renderSkill target name skill;
      }
    ) skillDefs;

  mkRuleEntries =
    base:
    lib.mapAttrs' (
      name: rule:
      lib.nameValuePair "${base}/rules/${name}.mdc" {
        text = renderCursorRule name rule;
      }
    ) ruleDefs;

  # Shared AGENTS.md source, consumed by Claude (as CLAUDE.md), the Cursor
  # shared-defaults rule, Codex (~/.codex/AGENTS.md) and Pi (~/.pi/agent/AGENTS.md).
  agentsMd = dataPath "AGENTS.md";

  # Codex and Pi have no subagents, so each specialist persona is exposed as an
  # ordinary invokable skill (its prompt becomes the skill body).
  renderAgentAsSkill =
    name: agent:
    ''
      ${renderFrontmatter {
        inherit name;
        description = agent.description;
      }}
      ${agent.prompt}
    '';

  # Skills that make sense outside Claude/Cursor. `session-resume` reads
  # ~/.claude paths, `specialist-routing` describes Claude/Cursor subagent
  # dispatch, and `skill-creator` is shipped by Codex itself (under
  # ~/.codex/skills/.system) — so none are shared to Codex/Pi.
  sharedSkillDefs = removeAttrs skillDefs [
    "session-resume"
    "specialist-routing"
    "skill-creator"
  ];

  sharedSkillTexts =
    (lib.mapAttrs (name: agent: renderAgentAsSkill name agent) agentDefs)
    // (lib.mapAttrs (name: skill: renderSkill "agents" name skill) sharedSkillDefs);

  # Codex and Pi discover skills by scanning ~/.agents/skills for real SKILL.md
  # files and skip symlinks — but home.file only creates symlinks. So assemble
  # the generated skills into a store directory here and copy them in as real
  # files via the seedAgentSkills activation script below.
  sharedSkillsDir = pkgs.symlinkJoin {
    name = "agent-skills";
    paths = lib.mapAttrsToList (
      name: text: pkgs.writeTextDir "${name}/SKILL.md" text
    ) sharedSkillTexts;
  };

  hookFileName = name: hook: hook.fileName or "${name}.sh";

  targetHookBindings = target: hook: if builtins.hasAttr target hook then hook.${target} else [ ];

  targetHookDefs =
    target:
    lib.filterAttrs (_: hook: targetHookBindings target hook != [ ]) hookDefs;

  mkHookScriptEntries =
    target: base:
    lib.mapAttrs' (
      name: hook:
      lib.nameValuePair "${base}/hooks/${hookFileName name hook}" {
        text = hook.script;
        executable = true;
      }
    ) (targetHookDefs target);

  claudeHooks =
    lib.foldl'
      (
        acc: name:
        let
          hook = hookDefs.${name};
          command = "\"$HOME/.claude/hooks/${hookFileName name hook}\"";
        in
        lib.foldl'
          (
            inner: binding:
            let
              event = binding.event;
              group =
                lib.optionalAttrs ((binding.matcher or null) != null) {
                  matcher = binding.matcher;
                }
                // {
                  hooks = [
                    ({
                      type = "command";
                      inherit command;
                    }
                    // lib.optionalAttrs ((binding.timeout or null) != null) {
                      timeout = binding.timeout;
                    }
                    // lib.optionalAttrs ((binding.statusMessage or null) != null) {
                      statusMessage = binding.statusMessage;
                    })
                  ];
                };
            in
            inner
            // {
              "${event}" = (inner.${event} or [ ]) ++ [ group ];
            }
          )
          acc
          (targetHookBindings "claude" hook)
      )
      { }
      (builtins.attrNames hookDefs);

  cursorHookConfig =
    lib.foldl'
      (
        acc: name:
        let
          hook = hookDefs.${name};
          command = "\"$HOME/.cursor/hooks/${hookFileName name hook}\"";
        in
        lib.foldl'
          (
            inner: binding:
            let
              event = binding.event;
              entry =
                {
                  inherit command;
                }
                // lib.optionalAttrs ((binding.timeout or null) != null) {
                  timeout = binding.timeout;
                }
                // lib.optionalAttrs ((binding.failClosed or null) != null) {
                  failClosed = binding.failClosed;
                }
                // lib.optionalAttrs ((binding.matcher or null) != null) {
                  matcher = binding.matcher;
                }
                // lib.optionalAttrs ((binding.type or null) != null) {
                  type = binding.type;
                };
            in
            inner
            // {
              "${event}" = (inner.${event} or [ ]) ++ [ entry ];
            }
          )
          acc
          (targetHookBindings "cursor" hook)
      )
      { }
      (builtins.attrNames hookDefs);

  claudeStatusLineScript = pkgs.writeShellScript "claude-statusline" ''
    input=$(cat)

    # Catppuccin Mocha palette (truecolor ANSI)
    gold='\033[38;2;246;193;119m'
    foam='\033[38;2;156;207;216m'
    lavender='\033[38;2;180;190;254m'
    rosewater='\033[38;2;245;224;220m'
    pine='\033[38;2;62;143;176m'
    reset='\033[0m'

    raw_dir=$(echo "$input" | ${pkgs.jq}/bin/jq -r '.workspace.current_dir // .cwd // empty')
    if [[ -n "$raw_dir" ]]; then
      dir="''${raw_dir/#$HOME/\~}"
    else
      dir="?"
    fi

    branch=$(GIT_OPTIONAL_LOCKS=0 ${pkgs.git}/bin/git -C "$raw_dir" symbolic-ref --quiet --short HEAD 2>/dev/null \
             || GIT_OPTIONAL_LOCKS=0 ${pkgs.git}/bin/git -C "$raw_dir" rev-parse --short HEAD 2>/dev/null)

    model=$(echo "$input" | ${pkgs.jq}/bin/jq -r '.model.display_name // empty')

    remaining=$(echo "$input" | ${pkgs.jq}/bin/jq -r '.context_window.remaining_percentage // empty')

    cost=$(echo "$input" | ${pkgs.jq}/bin/jq -r '.cost.total_cost_usd // empty')

    out=""
    out="''${out}''${gold}''${dir}''${reset}"

    if [[ -n "$branch" ]]; then
      out="''${out} ''${pine}|''${reset} ''${foam} ''${branch}''${reset}"
    fi

    out="''${out} ''${pine}|''${reset}"

    if [[ -n "$model" ]]; then
      out="''${out} ''${lavender}''${model}''${reset}"
    fi

    if [[ -n "$remaining" ]]; then
      printf_remaining=$(printf '%.0f' "$remaining")
      out="''${out} ''${pine}|''${reset} ''${rosewater}ctx:''${printf_remaining}%''${reset}"
    fi

    if [[ -n "$cost" ]]; then
      printf_cost=$(printf '%.4f' "$cost")
      out="''${out} ''${pine}|''${reset} ''${foam}\$''${printf_cost}''${reset}"
    fi

    printf "%b" "$out"
  '';

  claudeSettings =
    {
      "$schema" = "https://json.schemastore.org/claude-code-settings.json";
      permissions = claudePermissions;
      statusLine = {
        type = "command";
        command = "${claudeStatusLineScript}";
      };
      enabledPlugins = {
        "code-simplifier@claude-plugins-official" = true;
        "codex@openai-codex" = true;
      };
    }
    // lib.optionalAttrs (claudeHooksWithHerdr != { }) {
      hooks = claudeHooksWithHerdr;
    };

  cursorHooks = {
    version = 1;
    hooks = cursorHookConfig;
  };

  # Herdr session-identity hooks. Herdr's own `integration install` command
  # cannot be used for Claude/Cursor because it rewrites settings.json /
  # hooks.json in place, and this module renders those as read-only Nix-store
  # symlinks. Instead we vendor Herdr's hook scripts verbatim (the
  # HERDR_INTEGRATION_VERSION markers let `herdr integration status` recognise
  # them) and merge Herdr's hook entries into the JSON we already generate.
  # Re-extract the scripts (run `herdr integration install {claude,cursor}` in a
  # scratch HOME) whenever the pinned Herdr version bumps the hook version.
  herdrClaudeHookGroup = {
    matcher = "*";
    hooks = [
      {
        type = "command";
        command = "bash \"$HOME/.claude/hooks/herdr-agent-state.sh\" session";
        timeout = 10;
      }
    ];
  };

  herdrCursorHookEntry = {
    command = "bash \"$HOME/.cursor/herdr-agent-state.sh\" session";
  };

  claudeHooksWithHerdr =
    if cfg.enableHerdr then
      claudeHooks
      // {
        SessionStart = (claudeHooks.SessionStart or [ ]) ++ [ herdrClaudeHookGroup ];
      }
    else
      claudeHooks;

  cursorHooksWithHerdr =
    if cfg.enableHerdr then
      cursorHooks
      // {
        hooks = cursorHookConfig // {
          sessionStart = (cursorHookConfig.sessionStart or [ ]) ++ [ herdrCursorHookEntry ];
        };
      }
    else
      cursorHooks;
in
{
  options.ai-agents = {
    enable = lib.mkEnableOption "shared Claude and Cursor specialist agents";

    enableClaude = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install shared agents and skills into ~/.claude.";
    };

    enableCursor = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install shared agents and skills into ~/.cursor.";
    };

    enableCodex = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the shared AGENTS.md into ~/.codex and shared skills into
        ~/.agents/skills. Codex has no subagents, so specialists are exposed as
        invokable skills.
      '';
    };

    enablePi = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the shared AGENTS.md into ~/.pi/agent and shared skills into
        ~/.agents/skills. Pi has no subagents, so specialists are exposed as
        invokable skills.
      '';
    };

    enableHerdr = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Wire Herdr session-identity integrations for Claude, Cursor, Codex and
        Pi. Claude and Cursor are wired declaratively (vendored hook scripts +
        merged settings). Codex and Pi live outside this module's file
        management, so they are installed with `herdr integration install`
        during home-manager activation. Requires the `herdr` CLI on PATH.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.file =
      lib.optionalAttrs cfg.enableClaude (
        mkAgentEntries "claude" ".claude"
        // mkSkillEntries "claude" ".claude"
        // mkHookScriptEntries "claude" ".claude"
        // {
          ".claude/CLAUDE.md".source = agentsMd;
          ".claude/settings.json".text = builtins.toJSON claudeSettings + "\n";
        }
        // lib.optionalAttrs cfg.enableHerdr {
          ".claude/hooks/herdr-agent-state.sh".source = dataPath "defs/herdr/claude-agent-state.sh";
        }
      )
      // lib.optionalAttrs cfg.enableCursor (
        mkAgentEntries "cursor" ".cursor"
        // mkSkillEntries "cursor" ".cursor"
        // mkHookScriptEntries "cursor" ".cursor"
        // mkRuleEntries ".cursor"
        // {
          ".cursor/hooks.json".text = builtins.toJSON cursorHooksWithHerdr + "\n";
        }
        // lib.optionalAttrs cfg.enableHerdr {
          ".cursor/herdr-agent-state.sh".source = dataPath "defs/herdr/cursor-agent-state.sh";
        }
      )
      // lib.optionalAttrs cfg.enableCodex {
        ".codex/AGENTS.md".source = agentsMd;
      }
      // lib.optionalAttrs cfg.enablePi {
        ".pi/agent/AGENTS.md".source = agentsMd;
      };

    home.activation = {
      # Codex and Pi discover skills from ~/.agents/skills but skip symlinked
      # SKILL.md files, which is all home.file can produce. Copy the generated
      # skills in as real files (same seed pattern used for helix/zellij here).
      # Only our own skill names are replaced; other skills in the dir (e.g.
      # agent-catalog) are left untouched.
      seedAgentSkills = lib.mkIf (cfg.enableCodex || cfg.enablePi) (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          dest="$HOME/.agents/skills"
          $DRY_RUN_CMD mkdir -p "$dest"
          for src in ${sharedSkillsDir}/*/; do
            name="$(basename "$src")"
            $DRY_RUN_CMD rm -rf "$dest/$name"
            $DRY_RUN_CMD cp -RL "$src" "$dest/$name"
            $DRY_RUN_CMD chmod -R u+w "$dest/$name"
          done
        ''
      );

      # Codex and Pi keep their Herdr config outside this module's file
      # management, so Herdr's own installer can safely write them. It is
      # idempotent, so running it on every activation just re-asserts the
      # current pinned integration.
      herdrIntegrations = lib.mkIf cfg.enableHerdr (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          herdr_bin="${pkgs.herdr}/bin/herdr"
          if [ -x "$herdr_bin" ]; then
            $DRY_RUN_CMD mkdir -p "$HOME/.pi/agent/extensions"
            $DRY_RUN_CMD "$herdr_bin" integration install pi || true
            $DRY_RUN_CMD "$herdr_bin" integration install codex || true
          fi
        ''
      );
    };
  };
}
