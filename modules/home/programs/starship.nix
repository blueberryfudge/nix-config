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

        format = "$directory$git_branch$git_status$fill$time$line_break$username$character";
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
          format = "[$user](fg:black bg:surface0)";
        };

        directory = {
          style = "fg:gold";
          format = "[$path ]($style) ";
          # truncation_length = 3;
          # truncation_symbol = "…/";
        };

        git_branch = {
          format = "[$symbol$branch]($style)";
          style = "fg:foam";
          symbol = " ";
        };

        git_status = {
          disabled = false;
          style = "fg:yellow";
          format = "($style)[ ($all_status$ahead_behind)](fg:foam)";
            up_to_date = "[✓]( fg:mauve)";
            untracked = "[?($count)]( fg:rosewater)";
            stashed = "[$count]( fg:mauve)";
            modified = "[!($count)]( fg:rosewater)";
            renamed = "[»($count)]( fg:mauve)";
            deleted = "[✘($count)](style)";
            staged = "[++($count)]( fg:rosewater)";
            ahead = "[⇡($count)](fg:lavender)";
            diverged = "⇕[\[](fg:mauve)[⇡($ahead_count)](fg:lavender)[⇣($behind_count)](fg:pink)[\]](fg:mauve)";
            behind = "[⇣($count)](fg:pink)";
        };

        c = {
          symbol = " ";
          style = "bg:green";
          format = "[[ $symbol( $version) ](fg:crust bg:green)]($style)";
        };

        rust = {
          symbol = "";
          style = "bg:surface2";
          format = "[[ $symbol( $version) ](fg:crust)]($style)";
        };

        golang = {
          symbol = "";
          style = "bg:surface2";
          format = "[[ $symbol( $version) ](fg:surface2)]($style)";
        };

        java = {
          symbol = " ";
          style = "bg:surface2";
          format = "[[ $symbol( $version) ](fg:crust)]($style)";
        };

        scala = {
          symbol = "🆂  ";
          style = "fg:surface0";
          format = "[[ $symbol( $version) ](fg:surface1)]($style)";
          detect_extensions = ["scala" "sbt" "mill"];
          # detect_files = ["build.sbt" ".scalaenv" ".sbtenv" "build.sc" ".mill"];
          disabled = true;
        };

        kotlin = {
          symbol = " ";
          style = "bg:surface2";
          format = "[[ $symbol( $version) ](fg:crust)]($style)";
        };

        nix_shell = {
          symbol = "";
          style = "fg:surface1";
          format = "[$state( \\($name\\))]($style) ";
        };

        python = {
          symbol = "";
          style = "bg:surface2";
          format = "[[ $symbol( $version)(\\(#$virtualenv\\)) ](fg:crust)]($style)";
        };

        docker_context = {
          symbol = "";
          style = "bg:surface2";
          format = "[[ $symbol( $context) ](fg:crust)]($style)";
        };

        time = {
          disabled = true;
          time_format = "%R";
          style = "bg:surface2";
          format = "[ $time]($style)";

        };

        line_break = {
          disabled = false;
        };

        character = {
          disabled = false;
          success_symbol = "[ ➜](bold fg:pine)";
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
          love = "#eb6f92"; #rose-pine moon
          gold = "#f6c177"; #rose-pine gold
          pine = "#3e8fb0"; #rose-pine pine
          foam = "#9ccfd8"; #rose-pine foam
          iris = "#c4a7e7"; #rose-pine iris
          rose = "#ea9a97"; #rose-pine rose
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
