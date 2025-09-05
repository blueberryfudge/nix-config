{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:

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
      tenv
      inputs.lunar-tools.packages.${pkgs.system}.hamctl
      inputs.lunar-tools.packages.${pkgs.system}.shuttle
      # inputs.lunar-tools.packages.${pkgs.system}.dagger
    ];
  };
}
