{
  pkgs,
  lib,
  config,
  ...
}:

{
  options = {
    cli-tooling.enable = lib.mkEnableOption "enables cli tooling";
  };

  config = lib.mkIf config.cli-tooling.enable {
    # development tools
    home.packages = with pkgs; [
      # cli tools
      lazygit # tui git client
      yq # cli yaml processor
      jq # cli json processor
      curl # cli http client
      envsubst # cli env var substitution
      fd # user friendly alternative to find
      fzf
      coreutils
      kubectl
      kubelogin-oidc
      k9s

    ];

    # direnv
    programs.direnv = {
      enable = true;
    };
  };
}
