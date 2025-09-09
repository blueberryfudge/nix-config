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
  };
}
