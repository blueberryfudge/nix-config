{
  user,
  pkgs,
  enableHomebrew,
  ...
}:

{
  nix-homebrew = {
    inherit user;
    enable = enableHomebrew;
    enableRosetta = true;
    mutableTaps = true;


    # Note: if we want nix managed taps
    # taps = {
    #   "homebrew/core" = inputs.homebrew-core;
    #   "homebrew/cask" = inputs.homebrew-cask;
    #   "homebrew/bundle" = inputs.homebrew-bundle;
    # };
    # NOTE: below taps needed as flake inputs if using taps above
    # homebrew-bundle = {
    #   url = "github:homebrew/homebrew-bundle";
    #   flake = false;
    # };
    # homebrew-core = {
    #   url = "github:homebrew/homebrew-core";
    #   flake = false;
    # };
    # homebrew-cask = {
    #   url = "github:homebrew/homebrew-cask";
    #   flake = false;
    # };
  };

  homebrew = {
    enable = enableHomebrew;

    global = {
      brewfile = true;
      autoUpdate = true;
    };

    brewPrefix = "/opt/homebrew/bin"; # needed for arm64
    casks = pkgs.callPackage ./casks.nix { };

    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "none";
    };

    
    brews= pkgs.callPackage ./brews.nix { };

    # mas = mac app store
    # https://github.com/mas-cli/mas
    #
    # $ nix shell nixpkgs#mas
    # $ mas search <app name>
    # masApps = {
    #   "xcode" = 497799835;
    # };
  };
}
