{
  user,
  pkgs,
  hostModule,
  ...
}:
let
  # casksPath = "${hostModule}/casks.nix";
  casksPath = "/Users/edb/.config/nix-config/hosts/work/casks.nix";
  brewsPath = "${hostModule}/brews.nix";

  in
{
  nix-homebrew = {
    inherit user;
    enable = true;
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
    enable = true;

    global = {
      brewfile = true;
      autoUpdate = true;
    };

    brewPrefix = "/opt/homebrew/bin"; # needed for arm64
    casks = pkgs.callPackage casksPath { };

    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "none";
    };

    
    brews= pkgs.callPackage brewsPath { };

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
