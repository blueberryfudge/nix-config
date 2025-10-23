{
  inputs,
  pkgs,
  lib,
  config,
  gitConfig ? {},
  user ? "edb",
  ...
}:

let
  enableLunarTools = user == "edb";
  defaultSigned = gitConfig.enableSigning or true;
  cfg = {
    userName = gitConfig.userName or "Edvard Boguslavskij";
    userEmail = gitConfig.userEmail or "edvard.bgs@gmail.com";
    signingKey = gitConfig.signingKey or "/Users/${gitConfig.user or "edb"}/.ssh/id_ed25519";
    workSSHKey = gitConfig.workSSHKey or null;
    personalSSHKey = gitConfig.personalSSHKey or "/Users/${gitConfig.user or "edb"}/.ssh/id_ed25519";
    enableLunarUrls = gitConfig.enableLunarUrls or false;
    enablePersonalAlias = gitConfig.enablePersonalAlias or false;
    user = gitConfig.user or "edb";
  };
in
{
  options = {
    core-git.enable = lib.mkEnableOption "enables core (git, ssh) tooling";
  };

  config = lib.mkIf config.core-git.enable {
    home.packages = with pkgs; [
      gh ] ++ lib.optionals enableLunarTools [
      # NOTE: realistically only need one of the below
      gitnow
      sesh
    ];

    programs.git = {
      enable = true;

      ignores = [
        "*.swp"
        "*.tmp"
        ".DS_Store"
        "node_modules/"
        ".env.local"
        "*.log"
      ];

      signing = {
        key = cfg.signingKey;
        signByDefault = defaultSigned;
      };

      settings= {
        user = {
          name = cfg.userName;
          email = cfg.userEmail;
        };
        
        init.defaultBranch = "main";

        gpg.format = "ssh";

        core = {
          editor = "hx";
          autocrlf = "input";
        };
        
        pull.rebase = true;

        push = {
          default = "current";
          autoSetupRemote = true;
        };

        rebase.autoStash = true;

        branch.sort = "-committerdate";

        alias = {
          unstage = "reset HEAD --";
          last = "log -1 HEAD";
        };

        url."git@github.com:lunarway/" = lib.mkIf cfg.enableLunarUrls {
          insteadOf = "https://github.com/lunarway/";
        };

        # NOTE: this is an example config for reference
        includeIf."gitdir/i:/Users/${cfg.user}/git/github.com/blueberryfudge/" = lib.mkIf cfg.enablePersonalAlias {
            path = "~/.gitconfig_personal";
        };
        includeIf."gitdir/i:/Users/edb/.local/share/chezmoi/" = lib.mkIf cfg.enablePersonalAlias {
          path = "~/.gitconfig_personal";
        };
        includeIf."gitdir/i:/Users/edb/.config/nix-config/" = lib.mkIf cfg.enablePersonalAlias {
          path = "~/.gitconfig_personal";
        };
        url."git@github.com" = lib.mkIf (!cfg.enableLunarUrls) {
          insteadOf = "https://github.com";
        };
      };

    };

    # NOTE: this is an example config for reference
    home.file.".gitconfig_personal" = lib.mkIf cfg.enablePersonalAlias {
      text = ''
        [user]
          name = ${cfg.userName}
          email = edvard.bgs@gmail.com
          signingkey = ${cfg.personalSSHKey}

        [gpg]
          format = ssh
        [commit]
          gpgsign = true

        [url "git@github-blueberryfudge"]
          insteadOf = git@github.com

        [url "git@github-blueberryfudge"]
              pushInsteadOf = https://github.com

        [url "git@github-blueberryfudge"]
          insteadof = git@github.com/blueberryfudge

      '';
    };
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
        
      extraConfig = ''
        UseKeychain yes
      '';

      matchBlocks = {
        "github.com" = {
          user = "git";
          identityFile = if cfg.workSSHKey != null then cfg.workSSHKey else cfg.personalSSHKey;
          addKeysToAgent = "yes";
        };
      } // lib.optionalAttrs cfg.enablePersonalAlias {
        "github-blueberryfudge" = {
          hostname = "github.com";
          user = "git";
          identityFile = cfg.personalSSHKey;
          addKeysToAgent = "yes";
        };
      } // {
        "*" = {
          identitiesOnly = true;
          addKeysToAgent = "yes";
          forwardAgent = true;
        };
      };
    };
  };
}
