{
  inputs,
  pkgs,
  lib,
  config,
  user ? "edb", 
  ...
}:

let
  enableLunarTools = user == "edb";

in
{
  options = {
    devops-tooling.enable = lib.mkEnableOption "enables devops tooling (docker, k8s, dagger)";
  };

  config = lib.mkIf config.devops-tooling.enable {
    home.packages = with pkgs; [
      kubectl
      kubeseal
      awscli2
      # kubelogin-oidc must stay >= 1.36 to match the token-cache key algorithm
      # embedded in the lunarctl port-forward-cli plugin (kubelogin 1.36.0 added
      # AuthRequestExtraParams to the gob-encoded tokencache.Key, changing every
      # cache filename). On the work mac it is pinned from nixpkgs-unstable via
      # an overlay in work/flake.nix; nixpkgs-25.11 only ships 1.34.x.
      kubelogin-oidc
      krew
      kubernetes-helm
      fluxcd
      tenv] ++ lib.optionals enableLunarTools [
      pkgs.hamctl
      pkgs.shuttle
      # pkgs.dagger
    ];
  };
}
