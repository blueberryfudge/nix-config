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
        ".config/zellij/layouts/zjstatus.wasm".source = ./zellij/layouts/zjstatus.wasm;
      };

      home.activation.zellijMutableConfigs =
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          zellij_dir="$HOME/.config/zellij"
          layouts_dir="$zellij_dir/layouts"
          mkdir -p "$layouts_dir"

          src_config="${./zellij/config.kdl}"
          src_layout="${./zellij/layouts/custom.kdl}"

          seed_mutable() {
            local src="$1" dst="$2"
            if [ -L "$dst" ]; then
              rm -f "$dst"
            fi
            if [ ! -e "$dst" ]; then
              cp "$src" "$dst"
              chmod 644 "$dst"
            fi
          }

          seed_mutable "$src_config" "$zellij_dir/config.kdl"
          seed_mutable "$src_layout" "$layouts_dir/custom.kdl"
        '';
    };
  }
