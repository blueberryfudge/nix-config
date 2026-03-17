{
  inputs,
  pkgs,
  lib,
  config,
  nixDirectory ? "~/nix-conf",
  user ? "edb",
  ...
}:
{

  options = {
    core-zsh.enable = lib.mkEnableOption "enables core zsh tooling";
    core-zsh.enableLunar = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Lunar Zsh plugin and dotfiles.";
    };
  };

  config = lib.mkIf config.core-zsh.enable {
    home.packages = [
      pkgs.starship
      pkgs.lazygit
      pkgs.yazi
      pkgs.zellij
      pkgs.eza
      pkgs.bat
      pkgs.wget
      pkgs.zoxide
      pkgs.lunarctl
    ];

    programs.zsh = {
      enable = true;
      autocd = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;

      plugins = [
        {
          name = "zshdefer";
          src = pkgs.zsh-defer;
          file = "share/zsh-defer/zsh-defer.zsh";
        }
      ]
      ++ lib.optional config.core-zsh.enableLunar {
        name = "lunar";
        src = "${pkgs.lunar-zsh-plugin}/share/zsh/plugins/lunar-zsh-plugin/";
        file = "lunar.plugin.zsh";
      };

      shellAliases = {
        # Base aliases (always available)
        ls = "eza -all --icons";
        lg = "lazygit";
        nu = "pushd ${nixDirectory} && nix flake update && popd";
        ns = "pushd ${nixDirectory} && sudo darwin-rebuild switch --flake .#aarch64-darwin && popd"; # ← Fixed command
        gn = "gitnow";
        "docker-compose" = "docker compose";
        }
        # Lunar-specific aliases (only if enabled)
        // lib.optionalAttrs config.core-zsh.enableLunar {
        awsenv = "aws_fzf_profile";
        k8senv = "k8s_fzf_context";
        hubble = "aws_wrapper hubble";
        k9s = "k8s_wrapper k9s";
        helm = "k8s_wrapper helm";
        kubectl = "k8s_wrapper kubectl";
      };

      history.size = 10000;
      history.path = "${config.xdg.dataHome}/zsh/history";

      initContent =
        let
          zshConfigEarlyInit = lib.mkOrder 500 ''
            # Early NIX config
          '';

          zshConfig = lib.mkOrder 1000 ''
            # General NIX config
            if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
              . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
              . /nix/var/nix/profiles/default/etc/profile.d/nix.sh
            fi

            if [[ $(uname -m) == 'arm64' ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            fi

            # Opt-in auto-attach/create one Zellij session per project root.
            # Enable with: export ZELLIJ_AUTO_ATTACH=true
            # Disable with: export ZELLIJ_AUTO_ATTACH_DISABLE=1
            if [[ -o interactive && -z "$ZELLIJ" && -z "$SSH_CONNECTION" && "$ZELLIJ_AUTO_ATTACH" == "true" && -z "$ZELLIJ_AUTO_ATTACH_DISABLE" ]] && command -v zellij >/dev/null 2>&1; then
              function _zellij_auto_session_name() {
                local root base hash session_name

                if command -v git >/dev/null 2>&1; then
                  root="$(git rev-parse --show-toplevel 2>/dev/null || print -r -- "$PWD")"
                else
                  root="$PWD"
                fi

                if [[ "$root" == "/" ]]; then
                  base="root"
                else
                  base="''${root##*/}"
                  [[ -n "$base" ]] || base="shell"
                fi

                hash="$(print -rn -- "$root" | shasum | cut -c1-6)"
                session_name="''${base}-''${hash}"
                session_name="''${session_name//[^[:alnum:]_.-]/-}"
                print -r -- "$session_name"
              }

              zellij attach -c "$(_zellij_auto_session_name)"
              unset -f _zellij_auto_session_name
            fi

            # k8s plugin manager
            [[ -f $(which krew) ]] || export PATH="$HOME/.krew/bin:$PATH"

            # shuttle
            [[ ! -f $(which shuttle) ]] || source <(shuttle completion zsh)

            # gitnow 
            [[ ! -f $(which gitnow) ]] || source <(gitnow init zsh)

            # hamctl
            [[ ! -f $(which hamctl) ]] || source <(hamctl completion zsh)

            # Update Zellij pane titles (via OSC title) to "<dirname> (<git-branch>) [root-hash]".
            # This makes pane frames much more informative than "Pane #N".
            function _zellij_pane_title_update() {
              [[ -n "$ZELLIJ" ]] || return

              local dir branch pane_title root session_hash
              if [[ "$PWD" == "$HOME" ]]; then
                dir="~"
              elif [[ "$PWD" == "/" ]]; then
                dir="/"
              else
                dir="''${PWD##*/}"
              fi

              root="$PWD"
              if command -v git >/dev/null 2>&1; then
                root="$(git rev-parse --show-toplevel 2>/dev/null || print -r -- "$PWD")"
                if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)"
                fi
              fi
              session_hash="$(print -rn -- "$root" | shasum | cut -c1-6)"

              pane_title="$dir"
              if [[ -n "$branch" ]]; then
                pane_title="$dir ($branch)"
              fi
              pane_title="$pane_title [$session_hash]"

              printf '\e]2;%s\a' "$pane_title"
            }

            autoload -Uz add-zsh-hook
            add-zsh-hook chpwd _zellij_pane_title_update
            add-zsh-hook precmd _zellij_pane_title_update

            # refresh $GITHUB_ACCESS_TOKEN if unset
            if [[ $GITHUB_ACCESS_TOKEN == "" ]]; then
              export GITHUB_ACCESS_TOKEN=$(gh auth token);
            fi

            if [[ $GITHUB_LUNAR_CI_TOKEN = "" ]]; then
              export GITHUB_LUNAR_CI_TOKEN=$(gh auth token);
            fi

            if [[ $GITHUB_TOKEN == "" ]]; then
              export GITHUB_TOKEN=$(gh auth token);
            fi

            if [[ -z $SSH_AUTH_SOCK ]] || ! kill -0 $SSH_AGENT_PID 2>/dev/null; then
              eval "$(ssh-agent -s)" >/dev/null
            fi

            export PATH="$HOME/.local/bin:$PATH"
            export EDITOR='hx'
            export MANPAGER='hx +Man!'

            # Lunar-specific environment variables
            export LUNARCTL_REGISTRY="git=git@github.com:lunarway/lunarctl-registry.git"
          '';
        in
        lib.mkMerge [
          zshConfigEarlyInit
          zshConfig
        ];
    };

    programs.zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    programs.fzf = {
      enable = true;
      enableZshIntegration = true;
    };

    # Seed mutable local copies for tools that write to these files.
    home.activation.seedLunarConfigs = lib.mkIf config.core-zsh.enableLunar (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        mkdir -p "$HOME/.aws" "$HOME/.kube"

        if [ -L "$HOME/.aws/config" ] || [ ! -e "$HOME/.aws/config" ] || [ ! -w "$HOME/.aws/config" ]; then
          rm -f "$HOME/.aws/config"
          cp "${pkgs.lunar-zsh-plugin}/.aws/config" "$HOME/.aws/config"
          chmod 600 "$HOME/.aws/config"
        fi

        if [ -L "$HOME/.kube/config" ] || [ ! -e "$HOME/.kube/config" ] || [ ! -w "$HOME/.kube/config" ]; then
          rm -f "$HOME/.kube/config"
          cp "${pkgs.lunar-zsh-plugin}/.kube/config" "$HOME/.kube/config"
          chmod 600 "$HOME/.kube/config"
        fi
      ''
    );

  };
}
