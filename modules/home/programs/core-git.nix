{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:

let
  defaultSigned = true;
in
{
  options = {
    core-git.enable = lib.mkEnableOption "enables core (git, ssh) tooling";
  };

  config = lib.mkIf config.core-git.enable {
    home.packages = with pkgs; [
      gh
      # NOTE: realistically only need one of the below
      inputs.lunar-tools.packages.${pkgs.system}.gitnow
      inputs.lunar-tools.packages.${pkgs.system}.sesh
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

      userName = "Edvard Boguslavskij";
      userEmail = "edb@lunar.app";

      signing = {
        key = "/Users/edb/.ssh/github.pub";
        signByDefault = defaultSigned;
      };

      extraConfig = {
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

        url."git@github.com:lunarway/" = {
          insteadOf = "https://github.com/lunarway/";
        };

        # NOTE: this is an example config for reference
        includeIf."gitdir/i:/Users/edb/git/github.com/blueberryfudge/" = {
          path = "~/.gitconfig_personal";
        };
        includeIf."gitdir/i:/Users/edb/.local/share/chezmoi/" = {
          path = "~/.gitconfig_personal";
        };
        includeIf."gitdir/i:/Users/edb/.config/nix-config/" = {
          path = "~/.gitconfig_personal";
        };
      };

      aliases = {
        unstage = "reset HEAD --";
        last = "log -1 HEAD";
      };
    };

    # NOTE: this is an example config for reference
    home.file.".gitconfig_personal" = {
      text = ''
        [user]
          name = Edvard Boguslavskij
          email = edvard.bgs@gmail.com
          signingkey = /Users/edb/.ssh/id_ed25519
        
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
      matchBlocks = {
        "github.com" = {
          user = "git";
          identityFile = "/Users/edb/.ssh/github";
          addKeysToAgent = "yes";
          # useKeychain = true;
        };
        "github-blueberryfudge" = {
          user = "git";
          identityFile = "/Users/edb/.ssh/id_ed25519";
          addKeysToAgent = "yes";
          # useKeychain = true;
        };

        # NOTE: don't need to add blocks for other directories if sshCommand is set in config

        "*" = {
          addKeysToAgent = "yes";
          # useKeychain = true;
          identitiesOnly = true;
        };
      };
    };
  };
}
