{
  pkgs,
  lib,
  config,
  ...
}:
let
  toggleTheme = pkgs.writeShellScriptBin "toggle-theme" ''
    set -euo pipefail

    zellij_config="$HOME/.config/zellij/config.kdl"
    helix_config="$HOME/.config/helix/config.toml"
    layout_file="$HOME/.config/zellij/layouts/custom.kdl"
    state_file="$HOME/.cache/theme-switcher/current"

    mkdir -p "$(dirname "$state_file")"

    if [ "''${1:-}" = "dark" ] || [ "''${1:-}" = "light" ]; then
      mode="$1"
    else
      if defaults read -g AppleInterfaceStyle &>/dev/null; then
        mode="dark"
      else
        mode="light"
      fi
    fi

    prev=""
    [ -f "$state_file" ] && prev=$(cat "$state_file")
    [ "$prev" = "$mode" ] && exit 0

    if [ "$mode" = "light" ]; then
      zellij_theme="rose-pine-dawn"
      helix_theme="rose_pine_dawn"
      starship_palette="rose_pine_dawn"
      zj_bg="#faf4ed"
      zj_fg="#575279"
      zj_fg_dim="#9893a5"
      zj_accent="#286983"
      zj_warn="#ea9d34"
    else
      zellij_theme="catppuccin-mocha-custom"
      helix_theme="catppuccin_mocha"
      starship_palette="catppuccin_mocha"
      zj_bg="#1e1e2e"
      zj_fg="#9399B2"
      zj_fg_dim="#6C7086"
      zj_accent="#89B4FA"
      zj_warn="#ffc387"
    fi

    # Zellij config.kdl (theme line — picked up by running sessions)
    if [ -f "$zellij_config" ] && [ ! -L "$zellij_config" ]; then
      sed -i "" "s/^theme \".*\"/theme \"$zellij_theme\"/" "$zellij_config"
    fi

    # zjstatus color aliases in layout file
    if [ -f "$layout_file" ] && [ ! -L "$layout_file" ]; then
      sed -i "" \
        -e "s/color_bg     \".*\"/color_bg     \"$zj_bg\"/" \
        -e "s/color_fg     \".*\"/color_fg     \"$zj_fg\"/" \
        -e "s/color_fg_dim \".*\"/color_fg_dim \"$zj_fg_dim\"/" \
        -e "s/color_accent \".*\"/color_accent \"$zj_accent\"/" \
        -e "s/color_warn   \".*\"/color_warn   \"$zj_warn\"/" \
        "$layout_file"
    fi

    # Helix config.toml (SIGUSR1 triggers config reload in running instances)
    if [ -f "$helix_config" ] && [ ! -L "$helix_config" ]; then
      sed -i "" "s/^theme = \".*\"/theme = \"$helix_theme\"/" "$helix_config"
      pkill -USR1 hx 2>/dev/null || true
    fi

    # Starship palette (runtime, no file rewrite needed)
    if command -v starship &>/dev/null; then
      starship config palette "$starship_palette" 2>/dev/null || true
    fi

    printf '%s' "$mode" > "$state_file"
  '';
in
{
  options = {
    theme-switcher.enable = lib.mkEnableOption "macOS dark/light theme auto-switcher";
  };

  config = lib.mkIf config.theme-switcher.enable {
    home.packages = [ toggleTheme ];
  };
}
