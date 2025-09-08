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
      kubelogin
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
