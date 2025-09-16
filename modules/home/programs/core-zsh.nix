{
  inputs,
  pkgs,
  lib,
  config,
  nixDirectory ? "~/nix-conf",
  user ? "edb",
  ...
}:

let
  # Derive lunar tools from user
  enableLunarTools = user == "edb";
in
{
  options = {
    core-zsh.enable = lib.mkEnableOption "enables core zsh tooling";
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
      ] ++ lib.optionals enableLunarTools [
        {
          name = "lunar";
          src = "${pkgs.lunar-zsh-plugin}/share/zsh/plugins/lunar-zsh-plugin/";
          file = "lunar.plugin.zsh";
        }
      ];

      shellAliases = {
        # Base aliases (always available)
        ls = "eza -all --icons";
        lg = "lazygit";
        nu = "pushd ${nixDirectory} && nix flake update && popd";
        ns = "pushd ${nixDirectory} && sudo darwin-rebuild switch --flake .#aarch64-darwin && popd";  # ← Fixed command
        gn = "gitnow";
        "docker-compose" = "docker compose";
      } // lib.optionalAttrs enableLunarTools {
        # Lunar-specific aliases (only if enabled)
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

            # k8s plugin manager
            [[ -f $(which krew) ]] || export PATH="$HOME/.krew/bin:$PATH"
            
            ${lib.optionalString enableLunarTools ''
            # shuttle
            [[ ! -f $(which shuttle) ]] || source <(shuttle completion zsh)

            # gitnow 
            [[ ! -f $(which gitnow) ]] || source <(gitnow init zsh)

            # hamctl
            [[ ! -f $(which hamctl) ]] || source <(hamctl completion zsh)
            ''}

            # starship
            [[ ! -f $(which starship) ]] || source <(starship init zsh)

            # refresh $GITHUB_ACCESS_TOKEN if unset
            if [[ $GITHUB_ACCESS_TOKEN == "" ]]; then
              export GITHUB_ACCESS_TOKEN=$(gh auth token);
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

            ${lib.optionalString enableLunarTools ''
            # Lunar-specific environment variables
            export LUNARCTL_REGISTRY="git=git@github.com:lunarway/lunarctl-registry.git"
            ''}
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

    # Only create lunar config files if lunar tools are enabled
  } // lib.optionalAttrs enableLunarTools {
    home.file.".aws/config".source = "${pkgs.lunar-zsh-plugin}/.aws/config";
    home.file.".kube/config".source = "${pkgs.lunar-zsh-plugin}/.kube/config";
  };
}
