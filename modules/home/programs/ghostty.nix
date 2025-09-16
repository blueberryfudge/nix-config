{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:
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
    home.packages = with pkgs; [
      ghostty
    ];

    home.file.".config/ghostty/config".text = ''
      theme = ${config.ghostty.theme}

      cursor-style = block
      cursor-color = #727af4

      window-padding-x = 5
      window-padding-y = 5
      window-decoration = auto
      macos-titlebar-style = hidden
      window-height = ${toString config.ghostty.windowHeight}
      window-width = ${toString config.ghostty.windowWidth}
      window-save-state = always

      font-size = ${toString config.ghostty.fontSize}
    '';
  
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
      selection-background = 353749
      selection-foreground = cdd6f4
    '';
  };
}
