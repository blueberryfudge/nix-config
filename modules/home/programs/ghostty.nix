{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:
let
  # The Ghostty flake overlay in this repo currently exposes Linux-only builds.
  installGhosttyFromNix = pkgs.stdenv.hostPlatform.isLinux;
in
{
  options = {
    ghostty.enable = lib.mkEnableOption "enables ghostty terminal";
    ghostty.theme = lib.mkOption {
      type = lib.types.str;
      default = "catppuccin-mocha";
      description = "ghostty theme";
    };
    ghostty.fontSize = lib.mkOption {
      type = lib.types.int;
      default = 15;
      description = "ghostty font size";
    };
    ghostty.fontFamily = lib.mkOption {
      type = lib.types.str;
      default = "Monaspace Neon";
      description = "ghostty font family";
    };
    ghostty.fontThicken = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to thicken Ghostty font strokes (macOS only).";
    };
    ghostty.fontThickenStrength = lib.mkOption {
      type = lib.types.ints.between 0 255;
      default = 10;
      description = "Ghostty font thickening strength, from 0 to 255 (macOS only).";
    };
    ghostty.windowWidth = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "ghostty window width";
    };
    ghostty.windowHeight = lib.mkOption {
      type = lib.types.int;
      default = 25;
      description = "ghostty window height";
    };
  };

  config = lib.mkIf config.ghostty.enable {
    home.packages = lib.optionals installGhosttyFromNix [
      pkgs.ghostty
    ];

    home.file.".config/ghostty/config" = {
      force = true;
      text = ''
      theme = light:Rose Pine Dawn,dark:${config.ghostty.theme}

      cursor-style = block
      cursor-color = #727af4

      window-padding-x = 5
      window-padding-y = 5
      window-decoration = auto
      macos-titlebar-style = hidden
      window-height = ${toString config.ghostty.windowHeight}
      window-width = ${toString config.ghostty.windowWidth}
      window-save-state = always

      macos-option-as-alt = true

      keybind = alt+left=unbind
      keybind = alt+right=unbind


      font-size = ${toString config.ghostty.fontSize}
      font-family = "${config.ghostty.fontFamily}"
      font-family = "monospace"
      font-thicken = ${if config.ghostty.fontThicken then "true" else "false"}
      font-thicken-strength = ${toString config.ghostty.fontThickenStrength}
    '';
    };
  
    home.file.".config/ghostty/themes/catppuccin-mocha".text = ''
      palette = 0=#45475a
      palette = 1=#f38ba8
      palette = 2=#a6e3a1
      palette = 3=#f9e2af
      palette = 4=#89b4fa
      palette = 5=#f5c2e7
      palette = 6=#94e2d5
      palette = 7=#a6adc8
      palette = 8=#585b70
      palette = 9=#f38ba8
      palette = 10=#a6e3a1
      palette = 11=#f9e2af
      palette = 12=#89b4fa
      palette = 13=#f5c2e7
      palette = 14=#94e2d5
      palette = 15=#bac2de
      background = 1e1e2e
      foreground = cdd6f4
      cursor-color = f5e0dc
      cursor-text = 1e1e2e
      selection-background = f9e2af
      selection-foreground = 1e1e2e
    '';
  };
}
