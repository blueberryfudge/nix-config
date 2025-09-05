{ user, pkgs, ... }:

{
  imports = [
    ../../modules/darwin
    #../modules/shared
  ];

  nixpkgs = {
    config.allowUnfree = true;
  };

  users.users.${user} = with pkgs; {
    home = "/Users/${user}";
    shell = zsh;
  };

  ids.gids.nixbld = 350;

  nix = {
    enable = false;
    settings = {
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
  };

  # Turn off NIX_PATH warnings now that we're using flakes
  system.checks.verifyNixPath = false;

  environment.shells = with pkgs; [
    zsh
  ];
  programs.zsh.enable = true;

  # environment.variables = {
  #   EDITOR = "hx";
  #   VISUAL = "hx";
  # };

  security = {
    pam.services.sudo_local = {
      enable = true;
      reattach = true;
      touchIdAuth = true;
      watchIdAuth = true;
    };

    sudo = {
      extraConfig = ''
        Defaults  timestamp_timeout=5
      '';
    };
  };

  system = {
    stateVersion = 6;
    primaryUser = "${user}";

    defaults = {
      NSGlobalDomain = {
        AppleInterfaceStyle = "Dark";
        AppleShowAllExtensions = true;
        ApplePressAndHoldEnabled = false;
        NSWindowShouldDragOnGesture = true;

        # 120, 90, 60, 30, 12, 6, 2
        KeyRepeat = 2;

        # 120, 94, 68, 35, 25, 15
        InitialKeyRepeat = 15;

        # Automatically hide and show the menu bar
        # TODO: remove after sketchybar
        _HIHideMenuBar = false;

        "com.apple.mouse.tapBehavior" = 1;
        "com.apple.sound.beep.volume" = 0.0;
        "com.apple.sound.beep.feedback" = 0;
      };

      dock = {
        autohide = true;
        show-recents = false;
        launchanim = true;
        orientation = "left";
        tilesize = 48;
        mru-spaces = false;
      };

      finder = {
        AppleShowAllExtensions = true;
        _FXShowPosixPathInTitle = false;
      };

      trackpad = {
        Clicking = true;
        TrackpadThreeFingerDrag = false; # true is no bueno
      };

      screencapture.location = "~/Pictures/Screenshots";
      screensaver.askForPasswordDelay = 10; # in seconds
    };

    keyboard = {
      enableKeyMapping = true;
      remapCapsLockToEscape = true;
    };
  };
}
