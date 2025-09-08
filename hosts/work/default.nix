{ pkgs, user, ... }:

{
  imports = [
    ../../modules/darwin
    ../../modules/shared
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
    # Note: turn off for determinant systems nix
    # settings = {
    #   experimental-features = ["nix-command" "flakes"];
    #   max-jobs = "auto";
    #   cores = 0; # Use all cores
    #   trusted-users = [
    #     "@admin"
    #     "${user}"
    #   ];
    #   substituters = [
    #     "https://cache.nixos.org"
    #     "https://nix-community.cachix.org"
    #   ];
    #   trusted-public-keys = [
    #     "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    #     "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    #   ];
    # };

    # optimise = {
    #   automatic = true;
    #   interval = {
    #     Weekday = 4;
    #     Hour = 2;
    #     Minute = 0;
    #   };
    # };

    # gc = {
    #   automatic = true;
    #   interval = {
    #     Weekday = 0;
    #     Hour = 2;
    #     Minute = 0;
    #   };
    #   options = "--delete-older-than 30d";
    # };

    # extraOptions = ''
    #   extra-platforms = aarch64-darwin
    # '';

    # distributedBuilds = true;
  };
  # Turn off NIX_PATH warnings now that we're using flakes
  system.checks.verifyNixPath = false;

  environment.shells = with pkgs; [
    zsh
  ];
  programs.zsh.enable = true;

  environment.variables = {
    EDITOR = "hx";
    VISUAL = "hx";
  };

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
      };

      finder = {
        AppleShowAllExtensions = true;
        _FXShowPosixPathInTitle = false;
      };


      trackpad = {
        # Clicking = true;
        # TrackpadThreeFingerDrag = false; # true is no bueno
      };

      screencapture.location = "~/Pictures/Screenshots";
      #screensaver.askForPasswordDelay = 10; # in seconds
    };

    keyboard = {
      # enableKeyMapping = true;
      # remapCapsLockToEscape = true;
    };
  };
}
