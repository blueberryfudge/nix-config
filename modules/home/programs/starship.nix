{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:
{
  options = {
    starship.enable = lib.mkEnableOption "enables Starship prompt";
    starship.theme = lib.mkOption {
      type = lib.types.str;
      default = "catppuccin_mocha";
      description = "Starship color theme";
    };
  };
  config = lib.mkIf config.starship.enable {
    programs.starship = {
      enable = true;
      settings = {
        "$schema" = "https://starship.rs/config-schema.json";

        command_timeout = 1000;

        format = ''$directory$git_branch$git_status$fill$time
          $line_break$character'';
        right_format = "$c$rust$golang$nix_shell$java$kotlin$python$scala";
        palette = "catppuccin_mocha";

        fill = {
          style = "fg:base";
          symbol = " ";
        };

        username = {
          disabled = true;
          show_always = true;
          style_user = "bg:surface0 fg:surface2";
          style_root = "bg:surface0 fg:surface2";
          format = "[$user]($style)";
        };

        directory = {
          style = "bg:sky fg:crust";
          format = "[](fg:yellow)[󰀵 ](fg:black bg:yellow)[](fg:yellow bg:surface0)[ $path](fg:white bg:surface0)[](fg:surface0) ";
          # truncation_length = 3;
          # truncation_symbol = "…/";
        };

        git_branch = {
          format = "[](fg:green)[$symbol](fg:black bg:green)[](fg:green bg:surface0)[ $branch](fg:white bg:surface0)[](fg:surface0) ";
          symbol = " "
;
        };

        git_status = {
          disabled = false;
          style = "bg:yellow";
          format = "[](fg:sapphire)[ ](fg:black bg:sapphire)[](fg:sapphire bg:surface0)[ ($all_status$ahead_behind)](fg:white bg:surface0)[](fg:surface0)";
            up_to_date = "[ ✓ ](bg:surface0 fg:mauve)";
            untracked = "[? ($count)](bg:surface0 fg:rosewater)";
            stashed = "[ $](bg:surface0 fg:mauve)";
            modified = "[! ($count)](bg:surface0 fg:rosewater)";
            renamed = "[» ($count)](bg:surface0 fg:mauve)";
            deleted = "[✘ ($count)](style)";
            staged = "[++ ($count)](bg:surface0 fg:rosewater)";
            ahead = "[⇡ ($count)](bg:surface0 fg:lavender)";
            diverged = "⇕[\[](bg:surface0 fg:mauve)[⇡($ahead_count)](bg:surface0 fg:lavender)[⇣($behind_count)](bg:surface0 fg:pink)[\]](bg:surface0 fg:mauve)";
            behind = "[⇣ ($count)](bg:surface0 fg:pink)";
        };

        c = {
          symbol = " ";
          style = "bg:green";
          format = "[[ $symbol( $version) ](fg:crust bg:green)]($style)";
        };

        rust = {
          symbol = "";
          style = "bg:green";
          format = "[[ $symbol( $version) ](fg:crust bg:green)]($style)";
        };

        golang = {
          symbol = "";
          style = "bg:surface2";
          format = "[[ $symbol( $version) ](fg:surface2)]($style)";
        };

        java = {
          symbol = " ";
          style = "bg:green";
          format = "[[ $symbol( $version) ](fg:crust bg:green)]($style)";
        };

        scala = {
          symbol = "🆂  ";
          style = "fg:surface0";
          format = "[[ $symbol( $version) ](fg:surface1)]($style)";
        };

        kotlin = {
          symbol = " ";
          style = "bg:green";
          format = "[[ $symbol( $version) ](fg:crust bg:green)]($style)";
        };

        nix_shell = {
          symbol = "";
          style = "fg:surface1";
          format = "[$state( \\($name\\))]($style) ";
        };

        python = {
          symbol = "";
          style = "bg:green";
          format = "[[ $symbol( $version)(\\(#$virtualenv\\)) ](fg:crust bg:green)]($style)";
        };

        docker_context = {
          symbol = "";
          style = "bg:sapphire";
          format = "[[ $symbol( $context) ](fg:crust bg:sapphire)]($style)";
        };

        time = {
          disabled = false;
          time_format = "%R";
          style = "bg:lavender";
          #format = "[[  $time ](fg:crust bg:lavender)]($style)";
          format = "[](fg:mauve)[ ](fg:black bg:mauve)[](fg:mauve bg:surface0)[ $time](fg:white bg:surface0)[](fg:surface0) ";

        };

        line_break = {
          disabled = false;
        };

        character = {
          disabled = false;
          success_symbol = "[ ➜](bold green)";
          error_symbol = "[➜](bold fg:red)";
          vimcmd_symbol = "[❮](bold fg:green)";
          vimcmd_replace_one_symbol = "[❮](bold fg:lavender)";
          vimcmd_replace_symbol = "[❮](bold fg:lavender)";
          vimcmd_visual_symbol = "[❮](bold fg:yellow)";
        };

        cmd_duration = {
          show_milliseconds = true;
          format = " in $duration ";
          style = "bg:lavender";
          disabled = true;
          show_notifications = true;
          min_time_to_notify = 45000;
        };

        palettes.catppuccin_mocha = {
          rosewater = "#f5e0dc";
          flamingo = "#f2cdcd";
          pink = "#f5c2e7";
          mauve = "#cba6f7";
          red = "#f38ba8";
          maroon = "#eba0ac";
          peach = "#fab387";
          yellow = "#f9e2af";
          green = "#a6e3a1";
          teal = "#94e2d5";
          sky = "#89dceb";
          sapphire = "#74c7ec";
          blue = "#89b4fa";
          lavender = "#b4befe";
          text = "#cdd6f4";
          subtext1 = "#bac2de";
          subtext0 = "#a6adc8";
          overlay2 = "#9399b2";
          overlay1 = "#7f849c";
          overlay0 = "#6c7086";
          surface2 = "#585b70";
          surface1 = "#45475a";
          surface0 = "#313244";
          base = "#1e1e2e";
          mantle = "#181825";
          crust = "#11111b";
        };
      };
    };
  };
}
