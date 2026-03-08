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

  determinateNix = {
    enable = true;

    determinateNixd = {
      authentication.additionalNetrcSources = [
        "/etc/nix/netrc"
      ];
    };

    customSettings = {
      trusted-users = [
        "edb"
        "root"
      ];
      extra-substituters = [
        "https://cache.numtide.com"
      ];
      extra-trusted-public-keys = [
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      ];
    };
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
