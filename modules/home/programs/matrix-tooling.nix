{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:

{
  options = {
    matrix-tooling.enable = lib.mkEnableOption "enables matrix-tooling tooling";
  };

  config = lib.mkIf config.matrix-tooling.enable {
    home.packages = with pkgs; [
      # java/scala tooling
      scala-next # modern scala 3
      jdk17 # semi-modern jvm
      mill # modern scala build tool
      gradle # legacy scala/java build

      # python tooling
      uv # pip replacement
      python312 # generic programming language

      # data tooling
      duckdb # inprocess analytical database
      dbt # data build tool
      jupyter # notebook environment

      # misc
      devenv

      # lunar tooling
      inputs.lunar-tools.packages.${pkgs.system}.hubble
    ];
  };
}
