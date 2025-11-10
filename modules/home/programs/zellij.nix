{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:
  {
    options = {
      zellij.enable = lib.mkEnableOption "enables Zellij terminal multiplexer";
    };

    config = lib.mkIf config.zellij.enable {
      programs.zellij = {
        enable = true;
      };

      home.file = {
        ".config/zellij/config.kdl".source = ./zellij/config.kdl;
        ".config/zellij/layouts/custom.kdl".source = ./zellij/layouts/custom.kdl;
        ".config/zellij/layouts/zjstatus.wasm".source = ./zellij/layouts/zjstatus.wasm;
      };
    };
  }
