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
          file = "share/zsh-defer/zsh-defer.plugin.zsh";
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

            # Sync theme configs to current macOS appearance before Zellij starts.
            if command -v toggle-theme >/dev/null 2>&1; then
              toggle-theme
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

            # Defer completion sourcing past first prompt — each `source <(...)`
            # spawns the binary and adds 30–80ms to cold shell startup.
            zsh-defer -c '[[ ! -f $(which shuttle) ]] || source <(shuttle completion zsh)'
            zsh-defer -c '[[ ! -f $(which gitnow) ]] || source <(gitnow init zsh)'
            zsh-defer -c '[[ ! -f $(which hamctl) ]] || source <(hamctl completion zsh)'

            # Background watcher: polls macOS appearance every 2s and runs
            # toggle-theme on change. PID-guarded so only one survives across
            # all Ghostty windows — `&!` disowns the loop, so without this
            # guard every new outer shell would leak another watcher.
            if [[ -z "$ZELLIJ" ]] && command -v toggle-theme >/dev/null 2>&1; then
              local _theme_pid_file="$HOME/.cache/theme-switcher/watcher.pid"
              mkdir -p "''${_theme_pid_file:h}"

              local _theme_existing_pid=""
              [[ -f "$_theme_pid_file" ]] && _theme_existing_pid=$(<"$_theme_pid_file")

              if [[ -z "$_theme_existing_pid" ]] || ! kill -0 "$_theme_existing_pid" 2>/dev/null; then
                (
                  while true; do
                    toggle-theme 2>/dev/null
                    sleep 2
                  done
                ) &!
                print -r -- "$!" > "$_theme_pid_file"
              fi
              unset _theme_pid_file _theme_existing_pid
            fi

            # Hydrate GitHub token env vars after first prompt — `gh auth token`
            # hits the macOS keychain, and we only need to spend that cost
            # once per shell, not three times. Deferred so cold-shell paint
            # isn't blocked on it.
            zsh-defer -c '
              if [[ -z $GITHUB_TOKEN || -z $GITHUB_ACCESS_TOKEN || -z $GITHUB_LUNAR_CI_TOKEN ]] && command -v gh >/dev/null 2>&1; then
                local _gh_tok
                _gh_tok=$(gh auth token 2>/dev/null) || _gh_tok=""
                if [[ -n $_gh_tok ]]; then
                  [[ -z $GITHUB_TOKEN ]]         && export GITHUB_TOKEN=$_gh_tok
                  [[ -z $GITHUB_ACCESS_TOKEN ]]  && export GITHUB_ACCESS_TOKEN=$_gh_tok
                  [[ -z $GITHUB_LUNAR_CI_TOKEN ]] && export GITHUB_LUNAR_CI_TOKEN=$_gh_tok
                fi
              fi
            '

            if [[ -z $SSH_AUTH_SOCK ]] || ! kill -0 $SSH_AGENT_PID 2>/dev/null; then
              eval "$(ssh-agent -s)" >/dev/null
            fi

            export PATH="$HOME/.local/bin:$PATH"
            export EDITOR='hx'
            export MANPAGER='hx +Man!'

            # Lunar-specific environment variables
            export LUNARCTL_REGISTRY="git=git@github.com:lunarway/lunarctl-registry.git"
          '';

          zshViMode = lib.mkOrder 1100 ''
            # --- Vi mode: highlight/edit the command line with vim motions ---
            # Esc -> normal mode. `v` starts a visual selection; w/e/b/0/$/f
            # extend the highlight; `y` yanks (also to the macOS clipboard),
            # `d`/`c`/`x` cut, `p` pastes.
            bindkey -v
            export KEYTIMEOUT=1

            # Ctrl-V in normal mode opens the current command in $EDITOR (helix).
            autoload -Uz edit-command-line
            zle -N edit-command-line
            bindkey -M vicmd '^v' edit-command-line

            # In visual mode, also send the yanked selection to the clipboard.
            function _zsh_visual_yank_pbcopy {
              zle vi-yank
              printf '%s' "$CUTBUFFER" | pbcopy
            }
            zle -N _zsh_visual_yank_pbcopy
            bindkey -M visual 'y' _zsh_visual_yank_pbcopy

            # Cursor shape: block in normal mode, beam in insert mode.
            autoload -Uz add-zle-hook-widget
            function _zsh_vi_cursor_keymap {
              case $KEYMAP in
                vicmd) printf '\e[2 q' ;;
                *)     printf '\e[6 q' ;;
              esac
            }
            function _zsh_vi_cursor_init { printf '\e[6 q' }
            add-zle-hook-widget keymap-select _zsh_vi_cursor_keymap
            add-zle-hook-widget line-init _zsh_vi_cursor_init
          '';
        in
        lib.mkMerge [
          zshConfigEarlyInit
          zshConfig
          zshViMode
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
