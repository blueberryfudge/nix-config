{
  user,
  pkgs,
  hostModule,
  ...
}:
let
  casksPath = "${hostModule}/casks.nix";
  brewsPath = "${hostModule}/brews.nix";

  in
{
  nix-homebrew = {
    inherit user;
    enable = true;
    enableRosetta = true;
    mutableTaps = true;
    autoMigrate = true;
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
  };
}
