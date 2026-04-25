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
    code-documenter = import (dataPath "defs/agents/code-documenter.nix");
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

  hookDefs = {
    shell-guard = import (dataPath "defs/hooks/shell-guard.nix") { inherit pkgs; };
    session-context = import (dataPath "defs/hooks/session-context.nix") { inherit pkgs; };
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
    ask = [
      "Bash(curl *)"
      "Bash(wget *)"
      "Bash(nc *)"
      "Bash(ncat *)"
      "Bash(ssh *)"
      "Bash(scp *)"
      "Bash(rsync *)"
      "Bash(git push *)"
      "Bash(but push *)"
      "Bash(nix flake update *)"
      "Bash(home-manager switch *)"
      "Bash(darwin-rebuild switch *)"
    ];
    deny = [
      "Bash(rm -rf *)"
      "Bash(git reset --hard *)"
      "Bash(git clean -fd*)"
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
    // lib.optionalAttrs (claudeHooks != { }) {
      hooks = claudeHooks;
    };

  cursorHooks = {
    version = 1;
    hooks = cursorHookConfig;
  };
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
  };

  config = lib.mkIf cfg.enable {
    home.file =
      lib.optionalAttrs cfg.enableClaude (
        mkAgentEntries "claude" ".claude"
        // mkSkillEntries "claude" ".claude"
        // mkHookScriptEntries "claude" ".claude"
        // {
          ".claude/CLAUDE.md".source = dataPath "CLAUDE.md";
          ".claude/settings.json".text = builtins.toJSON claudeSettings + "\n";
        }
      )
      // lib.optionalAttrs cfg.enableCursor (
        mkAgentEntries "cursor" ".cursor"
        // mkSkillEntries "cursor" ".cursor"
        // mkHookScriptEntries "cursor" ".cursor"
        // mkRuleEntries ".cursor"
        // {
          ".cursor/hooks.json".text = builtins.toJSON cursorHooks + "\n";
        }
      );
  };
}
