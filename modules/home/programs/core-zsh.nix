{
  inputs,
  pkgs,
  lib,
  config,
  nixDirectory ? "~/nix-conf",
  ...
}:

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
    ];
    programs.zsh = {
      enable = true;
      autocd = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      # defaultKeymap = "viins";

      # NOTE: use-this for debugging performance issues
      #zprof.enable = true;

      plugins = [
        # {
        #   name = "powerlevel10k";
        #   src = pkgs.zsh-powerlevel10k;
        #   file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
        # }
        {
          name = "zshdefer";
          src = pkgs.zsh-defer;
          file = "share/zsh-defer/zsh-defer.zsh";
        }
        {
          name = "lunar";
          src = "${pkgs.lunar-zsh-plugin}/share/zsh/plugins/lunar-zsh-plugin/";
          file = "lunar.plugin.zsh";
        }
      ];

      shellAliases = {
        ls = "eza -all --icons";
        lg = "lazygit";
        nu = "pushd ${nixDirectory} && nix flake update && popd";
        ns = "pushd ${nixDirectory} && sudo darwin-rebuild --flake .#aarch64-darwin && popd";
        gn = "${pkgs.gitnow}/bin/gitnow-wrapper";
        awsenv = "aws_fzf_profile";
        k8senv = "k8s_fzf_context";
        "docker-compose" = "docker compose";
        hubble = "aws_wrapper hubble";
        k9s = "k8s_wrapper k9s";
        helm = "k8s_wrapper helm";
        kubectl = "k8s_wrapper kubectl";
      };

      history.size = 10000;
      history.path = "${config.xdg.dataHome}/zsh/history";

      # NOTE: 500: early init, 550: before comp, 1000: general, 1500: last
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
            # TODO: need to use enableHomebrew flag
            # if [[ $(uname -m) == 'arm64' ]]; then
            #     eval "$(/opt/homebrew/bin/brew shellenv)"
            # fi

            # k8s plugin manager
            [[ -f $(which krew) ]] || export PATH="$HOME/.krew/bin:$PATH"

            # powerlevel10k
            #[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

            # shuttle
            [[ ! -f $(which shuttle) ]] || source <(shuttle completion zsh)

            # hamctl
            [[ ! -f $(which hamctl) ]] || source <(hamctl completion zsh)

            # gitnow 
            [[ ! -f $(which gitnow) ]] || source <(gitnow init zsh)

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
            export LUNARCTL_REGISTRY="git=git@github.com:lunarway/lunarctl-registry.git"
            export EDITOR='hx'
            export MANPAGER='hx +Man!'

            # LW_PATH=~/lunar
            # GOPATH=~/go
            # GOBIN="$GOPATH/bin"
            # PATH="$PATH:/Users/edvard/.cargo/bin"
            # PATH="$GOBIN:$PATH"
            # export PATH=$PATH:/usr/local/go/bin
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

    #home.file.".p10k.zsh".source = "${nixfiles}/nix/config/zsh/p10k.zsh";
    home.file.".aws/config".source = "${pkgs.lunar-zsh-plugin}/.aws/config";
    home.file.".kube/config".source = "${pkgs.lunar-zsh-plugin}/.kube/config";
  };
}
